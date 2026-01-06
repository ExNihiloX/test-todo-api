#!/usr/bin/env bash
# ralph-claim.sh - Atomic feature claiming for parallel agents
# Uses portable mkdir locking to ensure only one agent claims a feature
#
# KEY DESIGN: State (status, claims, etc) is stored in STATE_FILE (progress/state.json)
# which is git-ignored. Specs (name, deps, acceptance criteria) are in PRD_FILE (prd.json)
# which is tracked in git. This prevents state divergence across feature branches.

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-lock.sh"

# =============================================================================
# STATE FUNCTIONS (read/write from STATE_FILE)
# =============================================================================

# Get feature state from state.json
get_feature_state() {
  local feature_id="$1"
  jq -r --arg id "$feature_id" '.features[] | select(.id == $id)' "$STATE_FILE"
}

# Get feature specs from prd.json (static, doesn't change)
get_feature_specs() {
  local feature_id="$1"
  jq -r --arg id "$feature_id" '.features[] | select(.id == $id)' "$PRD_FILE"
}

# Combined: get feature with both specs and state
get_feature() {
  local feature_id="$1"
  local specs state
  specs=$(get_feature_specs "$feature_id")
  state=$(get_feature_state "$feature_id")
  # Merge state into specs (state takes precedence for overlapping keys)
  echo "$specs" | jq --argjson state "$state" '. + $state'
}

# =============================================================================
# CLAIM FUNCTIONS
# =============================================================================

# Get list of claimable features (pending, dependencies met)
# Usage: get_claimable_features
get_claimable_features() {
  if [[ ! -f "$STATE_FILE" ]]; then
    log_error "State file not found: $STATE_FILE - run init_ralph first"
    return 1
  fi

  # Get completed feature IDs from state
  local completed
  completed=$(jq -r '[.features[] | select(.status == "completed") | .id]' "$STATE_FILE")

  # Find pending features where all dependencies are completed
  # Dependencies come from PRD_FILE (specs), status from STATE_FILE
  jq -r --argjson completed "$completed" '
    .features[] |
    select(
      # Check state for pending status
      (.id as $id | $completed | index($id) | not) and
      # Check specs for dependencies
      ((.depends_on // []) - $completed | length == 0)
    ) |
    .id
  ' "$PRD_FILE" | while read -r id; do
    # Double-check status in state file
    local status
    status=$(jq -r --arg id "$id" '.features[] | select(.id == $id) | .status' "$STATE_FILE")
    if [[ "$status" == "pending" ]]; then
      echo "$id"
    fi
  done
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

  # Check if feature is still claimable (from STATE_FILE)
  local current_status
  current_status=$(jq -r --arg id "$feature_id" '.features[] | select(.id == $id) | .status' "$STATE_FILE")

  if [[ "$current_status" != "pending" ]]; then
    log_warn "Feature $feature_id is no longer pending (status: $current_status)"
    release_lock "$lock_dir"
    return 1
  fi

  # Check dependencies are met (deps from PRD_FILE, status from STATE_FILE)
  local completed
  completed=$(jq -r '[.features[] | select(.status == "completed") | .id]' "$STATE_FILE")

  local deps_met
  deps_met=$(jq -r --arg id "$feature_id" --argjson completed "$completed" '
    .features[] | select(.id == $id) |
    ((.depends_on // []) - $completed | length == 0)
  ' "$PRD_FILE")

  if [[ "$deps_met" != "true" ]]; then
    log_warn "Feature $feature_id has unmet dependencies"
    release_lock "$lock_dir"
    return 1
  fi

  # Claim the feature (update STATE_FILE only)
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
  ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

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

  # Get completed features from state
  local completed
  completed=$(jq -r '[.features[] | select(.status == "completed") | .id]' "$STATE_FILE")

  # Get pending features from state
  local pending
  pending=$(jq -r '[.features[] | select(.status == "pending") | .id]' "$STATE_FILE")

  # Find highest priority claimable feature (priority from PRD, filtered by state)
  local feature_id
  feature_id=$(jq -r --argjson completed "$completed" --argjson pending "$pending" '
    [.features[] |
      select(.id as $id | $pending | index($id)) |
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

  # Claim it (update STATE_FILE only)
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
  ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

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
  ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

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
  ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

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
  ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

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
    ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  else
    jq --arg id "$feature_id" \
       --arg status "$status" '
      (.features[] | select(.id == $id)) |= . + {
        ci_status: $status
      }
    ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi

  release_lock "$lock_dir"
  return 0
}

# Get all in-progress features
# Usage: get_in_progress_features
get_in_progress_features() {
  jq -r '.features[] | select(.status == "in_progress") | .id' "$STATE_FILE"
}

# Get count of completed features
# Usage: get_completed_count
get_completed_count() {
  jq -r '[.features[] | select(.status == "completed")] | length' "$STATE_FILE"
}

# Get total feature count
# Usage: get_total_count
get_total_count() {
  jq -r '.features | length' "$STATE_FILE"
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
    completed-count)
      get_completed_count
      ;;
    total-count)
      get_total_count
      ;;
    help|*)
      echo "Usage: $0 {list|claim|claim-next|release|complete|block|status|in-progress|completed-count|total-count}"
      echo ""
      echo "Commands:"
      echo "  list                    - List claimable features"
      echo "  claim <id> <agent>      - Claim a specific feature"
      echo "  claim-next <agent>      - Claim next available feature"
      echo "  release <id> [reason]   - Release a claim"
      echo "  complete <id> [pr_url]  - Mark feature as completed"
      echo "  block <id> <reason>     - Mark feature as blocked"
      echo "  status <id>             - Get feature details (specs + state)"
      echo "  in-progress             - List all in-progress features"
      echo "  completed-count         - Get count of completed features"
      echo "  total-count             - Get total feature count"
      ;;
  esac
fi
