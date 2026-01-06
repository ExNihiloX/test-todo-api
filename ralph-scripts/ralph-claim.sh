#!/usr/bin/env bash
# ralph-claim.sh - Atomic feature claiming for parallel agents
# Uses portable mkdir locking to ensure only one agent claims a feature
#
# ARCHITECTURE: State vs Specs separation
# - PRD_FILE (prd.json): Static feature specs - tracked in git
# - STATE_FILE (state.json): Dynamic state - git-ignored to prevent branch divergence

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-lock.sh"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Get feature specs from PRD (static, git-tracked)
# Usage: get_feature_specs "feature_id"
get_feature_specs() {
  local feature_id="$1"
  jq -r --arg id "$feature_id" '.features[] | select(.id == $id)' "$PRD_FILE"
}

# Get feature state from STATE_FILE (dynamic, git-ignored)
# Usage: get_feature_state "feature_id"
get_feature_state() {
  local feature_id="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    init_ralph
  fi
  jq -r --arg id "$feature_id" '.features[] | select(.id == $id)' "$STATE_FILE"
}

# Get combined feature info (specs + state merged)
# Usage: get_feature "feature_id"
get_feature() {
  local feature_id="$1"
  local specs state
  specs=$(get_feature_specs "$feature_id")
  state=$(get_feature_state "$feature_id")

  # Merge state into specs (state overrides)
  echo "$specs" | jq --argjson state "$state" '. + $state'
}

# =============================================================================
# CLAIM FUNCTIONS
# =============================================================================

# Get list of claimable features (pending, dependencies met)
# Uses STATE_FILE for status, PRD_FILE for dependencies
# Usage: get_claimable_features
get_claimable_features() {
  if [[ ! -f "$PRD_FILE" ]]; then
    log_error "PRD file not found: $PRD_FILE"
    return 1
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    init_ralph
  fi

  # Get completed IDs from state
  local completed_ids
  completed_ids=$(jq -r '[.features[] | select(.status == "completed") | .id]' "$STATE_FILE")

  # Get pending IDs from state
  local pending_ids
  pending_ids=$(jq -r '[.features[] | select(.status == "pending") | .id]' "$STATE_FILE")

  # Find features that are pending AND have all dependencies completed
  jq -r --argjson completed "$completed_ids" --argjson pending "$pending_ids" '
    .features[] |
    select(.id as $id | $pending | contains([$id])) |
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
  lock_dir=$(acquire_lock "state-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock"
    return 1
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    init_ralph
  fi

  # Check if feature is still claimable (from state)
  local current_status
  current_status=$(jq -r --arg id "$feature_id" '.features[] | select(.id == $id) | .status' "$STATE_FILE")

  if [[ "$current_status" != "pending" ]]; then
    log_warn "Feature $feature_id is no longer pending (status: $current_status)"
    release_lock "$lock_dir"
    return 1
  fi

  # Check dependencies are met (deps from PRD, status from state)
  local completed_ids
  completed_ids=$(jq -r '[.features[] | select(.status == "completed") | .id]' "$STATE_FILE")

  local deps_met
  deps_met=$(jq -r --arg id "$feature_id" --argjson completed "$completed_ids" '
    .features[] | select(.id == $id) |
    ((.depends_on // []) - $completed | length == 0)
  ' "$PRD_FILE")

  if [[ "$deps_met" != "true" ]]; then
    log_warn "Feature $feature_id has unmet dependencies"
    release_lock "$lock_dir"
    return 1
  fi

  # Claim the feature (update state only)
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
  lock_dir=$(acquire_lock "state-claim" 10)

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    log_error "Could not acquire claim lock"
    return 1
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    init_ralph
  fi

  # Get completed and pending IDs from state
  local completed_ids
  completed_ids=$(jq -r '[.features[] | select(.status == "completed") | .id]' "$STATE_FILE")

  local pending_ids
  pending_ids=$(jq -r '[.features[] | select(.status == "pending") | .id]' "$STATE_FILE")

  # Find highest priority claimable feature (priority from PRD, status from state)
  local feature_id
  feature_id=$(jq -r --argjson completed "$completed_ids" --argjson pending "$pending_ids" '
    [.features[] |
      select(.id as $id | $pending | contains([$id])) |
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

  # Claim it (update state only)
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
  lock_dir=$(acquire_lock "state-claim" 10)

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
  lock_dir=$(acquire_lock "state-claim" 10)

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
  lock_dir=$(acquire_lock "state-claim" 10)

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
  lock_dir=$(acquire_lock "state-claim" 10)

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
  if [[ ! -f "$STATE_FILE" ]]; then
    init_ralph
  fi
  jq -r '.features[] | select(.status == "in_progress") | .id' "$STATE_FILE"
}

# Get progress summary
# Usage: get_progress
get_progress() {
  if [[ ! -f "$STATE_FILE" ]]; then
    init_ralph
  fi
  local completed pending in_progress blocked total
  completed=$(jq '[.features[] | select(.status == "completed")] | length' "$STATE_FILE")
  pending=$(jq '[.features[] | select(.status == "pending")] | length' "$STATE_FILE")
  in_progress=$(jq '[.features[] | select(.status == "in_progress")] | length' "$STATE_FILE")
  blocked=$(jq '[.features[] | select(.status == "blocked")] | length' "$STATE_FILE")
  total=$(jq '.features | length' "$STATE_FILE")

  echo "Progress: $completed/$total completed, $in_progress in progress, $pending pending, $blocked blocked"
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
    progress)
      get_progress
      ;;
    help|*)
      echo "Usage: $0 {list|claim|claim-next|release|complete|block|status|in-progress|progress}"
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
      echo "  progress                - Show overall progress summary"
      ;;
  esac
fi
