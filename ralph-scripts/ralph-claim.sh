#!/usr/bin/env bash
# ralph-claim.sh - Atomic feature claiming for parallel agents
# Uses portable mkdir locking to ensure only one agent claims a feature

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-lock.sh"

# =============================================================================
# CLAIM FUNCTIONS
# =============================================================================

# Get list of claimable features (pending, dependencies met)
# Usage: get_claimable_features
get_claimable_features() {
  if [[ ! -f "$PRD_FILE" ]]; then
    log_error "PRD file not found: $PRD_FILE"
    return 1
  fi

  jq -r '
    # Get completed feature IDs
    (.features | map(select(.status == "completed")) | map(.id)) as $completed |

    # Find pending features where all dependencies are completed
    .features[] |
    select(.status == "pending") |
    select((.depends_on // []) - $completed | length == 0) |
    .id
  ' "$PRD_FILE"
}

# Claim a specific feature for an agent
# Usage: claim_feature "feature_id" "agent_id"
# Returns: 0 on success, 1 if already claimed
claim_feature() {
  local feature_id="$1"
  local agent_id="$2"

  local lock_dir
  lock_dir=$(acquire_lock "prd-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock"
    return 1
  fi

  # Check if feature is still claimable
  local current_status
  current_status=$(jq -r --arg id "$feature_id" '.features[] | select(.id == $id) | .status' "$PRD_FILE")

  if [[ "$current_status" != "pending" ]]; then
    log_warn "Feature $feature_id is no longer pending (status: $current_status)"
    release_lock "$lock_dir"
    return 1
  fi

  # Check dependencies are met
  local deps_met
  deps_met=$(jq -r --arg id "$feature_id" '
    (.features | map(select(.status == "completed")) | map(.id)) as $completed |
    .features[] | select(.id == $id) |
    ((.depends_on // []) - $completed | length == 0)
  ' "$PRD_FILE")

  if [[ "$deps_met" != "true" ]]; then
    log_warn "Feature $feature_id has unmet dependencies"
    release_lock "$lock_dir"
    return 1
  fi

  # Claim the feature
  local timestamp
  timestamp=$(date -Iseconds)
  local branch="${FEATURE_BRANCH_PREFIX}/${feature_id}"

  jq --arg id "$feature_id" \
     --arg agent "$agent_id" \
     --arg ts "$timestamp" \
     --arg branch "$branch" '
    (.features[] | select(.id == $id)) |= . + {
      status: "in_progress",
      claimed_by: $agent,
      claimed_at: $ts,
      branch: $branch
    }
  ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"

  release_lock "$lock_dir"

  log "Agent $agent_id claimed feature $feature_id"
  notify_slack "🎯 Agent $agent_id claimed: $feature_id"

  echo "$feature_id"
  return 0
}

# Claim the next available feature (highest priority, deps met)
# Usage: claim_next_feature "agent_id"
claim_next_feature() {
  local agent_id="$1"

  local lock_dir
  lock_dir=$(acquire_lock "prd-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock"
    return 1
  fi

  # Find highest priority claimable feature
  local feature_id
  feature_id=$(jq -r '
    (.features | map(select(.status == "completed")) | map(.id)) as $completed |

    [.features[] |
      select(.status == "pending") |
      select((.depends_on // []) - $completed | length == 0)
    ] |
    sort_by(.priority) |
    first |
    .id // empty
  ' "$PRD_FILE")

  if [[ -z "$feature_id" || "$feature_id" == "null" ]]; then
    log "No claimable features available"
    release_lock "$lock_dir"
    return 1
  fi

  # Claim it
  local timestamp
  timestamp=$(date -Iseconds)
  local branch="${FEATURE_BRANCH_PREFIX}/${feature_id}"

  jq --arg id "$feature_id" \
     --arg agent "$agent_id" \
     --arg ts "$timestamp" \
     --arg branch "$branch" '
    (.features[] | select(.id == $id)) |= . + {
      status: "in_progress",
      claimed_by: $agent,
      claimed_at: $ts,
      branch: $branch
    }
  ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"

  release_lock "$lock_dir"

  log "Agent $agent_id claimed feature $feature_id (auto-selected)"
  notify_slack "🎯 Agent $agent_id claimed: $feature_id"

  echo "$feature_id"
  return 0
}

# Release a claim (on failure or timeout)
# Usage: release_claim "feature_id" [reason]
release_claim() {
  local feature_id="$1"
  local reason="${2:-released}"

  local lock_dir
  lock_dir=$(acquire_lock "prd-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock for release"
    return 1
  fi

  jq --arg id "$feature_id" '
    (.features[] | select(.id == $id)) |= . + {
      status: "pending",
      claimed_by: null,
      claimed_at: null
    }
  ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"

  release_lock "$lock_dir"

  log "Released claim on $feature_id: $reason"
  notify_slack "⚠️ Released claim: $feature_id ($reason)"

  return 0
}

# Mark a feature as completed
# Usage: complete_feature "feature_id" "pr_url"
complete_feature() {
  local feature_id="$1"
  local pr_url="${2:-}"

  local lock_dir
  lock_dir=$(acquire_lock "prd-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock for completion"
    return 1
  fi

  local timestamp
  timestamp=$(date -Iseconds)

  jq --arg id "$feature_id" \
     --arg ts "$timestamp" \
     --arg pr "$pr_url" '
    (.features[] | select(.id == $id)) |= . + {
      status: "completed",
      completed_at: $ts,
      pr_url: $pr
    }
  ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"

  release_lock "$lock_dir"

  log "Feature completed: $feature_id"
  notify_slack "✅ Feature completed: $feature_id ${pr_url:+- $pr_url}"

  return 0
}

# Mark a feature as blocked (needs human intervention)
# Usage: block_feature "feature_id" "reason"
block_feature() {
  local feature_id="$1"
  local reason="$2"

  local lock_dir
  lock_dir=$(acquire_lock "prd-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock for blocking"
    return 1
  fi

  jq --arg id "$feature_id" \
     --arg reason "$reason" '
    (.features[] | select(.id == $id)) |= . + {
      status: "blocked",
      blocked_reason: $reason
    }
  ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"

  release_lock "$lock_dir"

  log_warn "Feature blocked: $feature_id - $reason"
  notify_slack "🚫 BLOCKED: $feature_id - $reason (needs human help)"

  return 0
}

# Update CI status for a feature
# Usage: update_ci_status "feature_id" "status" [increment_attempts]
update_ci_status() {
  local feature_id="$1"
  local status="$2"
  local increment="${3:-false}"

  local lock_dir
  lock_dir=$(acquire_lock "prd-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    return 1
  fi

  if [[ "$increment" == "true" ]]; then
    jq --arg id "$feature_id" \
       --arg status "$status" '
      (.features[] | select(.id == $id)) |= . + {
        ci_status: $status,
        ci_attempts: ((.ci_attempts // 0) + 1)
      }
    ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"
  else
    jq --arg id "$feature_id" \
       --arg status "$status" '
      (.features[] | select(.id == $id)) |= . + {
        ci_status: $status
      }
    ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"
  fi

  release_lock "$lock_dir"
  return 0
}

# Get feature details
# Usage: get_feature "feature_id"
get_feature() {
  local feature_id="$1"
  jq -r --arg id "$feature_id" '.features[] | select(.id == $id)' "$PRD_FILE"
}

# Get all in-progress features
# Usage: get_in_progress_features
get_in_progress_features() {
  jq -r '.features[] | select(.status == "in_progress") | .id' "$PRD_FILE"
}

# =============================================================================
# MAIN - CLI interface
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-help}" in
    list)
      get_claimable_features
      ;;
    claim)
      claim_feature "$2" "$3"
      ;;
    claim-next)
      claim_next_feature "$2"
      ;;
    release)
      release_claim "$2" "${3:-manual}"
      ;;
    complete)
      complete_feature "$2" "${3:-}"
      ;;
    block)
      block_feature "$2" "$3"
      ;;
    status)
      get_feature "$2"
      ;;
    in-progress)
      get_in_progress_features
      ;;
    help|*)
      echo "Usage: $0 {list|claim|claim-next|release|complete|block|status|in-progress}"
      echo ""
      echo "Commands:"
      echo "  list                    - List claimable features"
      echo "  claim <id> <agent>      - Claim a specific feature"
      echo "  claim-next <agent>      - Claim next available feature"
      echo "  release <id> [reason]   - Release a claim"
      echo "  complete <id> [pr_url]  - Mark feature as completed"
      echo "  block <id> <reason>     - Mark feature as blocked"
      echo "  status <id>             - Get feature details"
      echo "  in-progress             - List all in-progress features"
      ;;
  esac
fi
