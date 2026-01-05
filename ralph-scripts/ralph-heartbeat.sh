#!/usr/bin/env bash
# ralph-heartbeat.sh - Detect and release stale claims
# Runs alongside orchestrator to recover from crashed agents

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-claim.sh"

# =============================================================================
# HEARTBEAT DAEMON
# =============================================================================

# Update heartbeat for an agent
# Usage: touch_heartbeat "agent_id"
touch_heartbeat() {
  local agent_id="$1"
  local heartbeat_file="${PROGRESS_DIR}/.heartbeat-${agent_id}"
  date -Iseconds > "$heartbeat_file"
}

# Check if an agent's heartbeat is fresh
# Usage: is_agent_alive "agent_id"
# Returns: 0 if alive, 1 if stale
is_agent_alive() {
  local agent_id="$1"
  local heartbeat_file="${PROGRESS_DIR}/.heartbeat-${agent_id}"

  if [[ ! -f "$heartbeat_file" ]]; then
    return 1
  fi

  local last_heartbeat
  last_heartbeat=$(cat "$heartbeat_file")
  local last_ts
  last_ts=$(date -d "$last_heartbeat" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${last_heartbeat%%+*}" +%s 2>/dev/null || echo 0)
  local now_ts
  now_ts=$(date +%s)
  local age=$((now_ts - last_ts))

  if [[ $age -gt $STALE_CLAIM_THRESHOLD ]]; then
    return 1
  fi

  return 0
}

# Find and release stale claims
# Usage: release_stale_claims
release_stale_claims() {
  if [[ ! -f "$PRD_FILE" ]]; then
    return 0
  fi

  # Get all in-progress features with their claim timestamps
  local stale_features
  stale_features=$(jq -r --argjson threshold "$STALE_CLAIM_THRESHOLD" '
    .features[] |
    select(.status == "in_progress") |
    select(.claimed_at != null) |
    select(
      (now - (.claimed_at | sub("\\+.*$"; "Z") | fromdateiso8601)) > $threshold
    ) |
    "\(.id)|\(.claimed_by)|\(.claimed_at)"
  ' "$PRD_FILE" 2>/dev/null || true)

  if [[ -z "$stale_features" ]]; then
    log_debug "No stale claims found"
    return 0
  fi

  while IFS='|' read -r feature_id agent_id claimed_at; do
    if [[ -z "$feature_id" ]]; then
      continue
    fi

    # Double-check by verifying agent heartbeat
    if ! is_agent_alive "$agent_id"; then
      log_warn "Releasing stale claim: $feature_id (agent: $agent_id, claimed: $claimed_at)"
      release_claim "$feature_id" "stale (agent $agent_id unresponsive)"
    fi
  done <<< "$stale_features"
}

# Check for features stuck in CI failure loop
# Usage: check_ci_failures
check_ci_failures() {
  if [[ ! -f "$PRD_FILE" ]]; then
    return 0
  fi

  # Find features that have exceeded max CI attempts
  local failed_features
  failed_features=$(jq -r --argjson max "$MAX_CI_ATTEMPTS" '
    .features[] |
    select(.ci_status == "failed") |
    select((.ci_attempts // 0) >= $max) |
    .id
  ' "$PRD_FILE" 2>/dev/null || true)

  for feature_id in $failed_features; do
    if [[ -n "$feature_id" ]]; then
      log_warn "Feature $feature_id exceeded max CI attempts ($MAX_CI_ATTEMPTS)"
      block_feature "$feature_id" "CI failed $MAX_CI_ATTEMPTS times"
    fi
  done
}

# Main heartbeat loop
# Usage: run_heartbeat_daemon
run_heartbeat_daemon() {
  log "Heartbeat daemon started (threshold: ${STALE_CLAIM_THRESHOLD}s, interval: ${HEARTBEAT_INTERVAL}s)"

  while true; do
    sleep "$HEARTBEAT_INTERVAL"

    # Check budget before continuing
    if ! check_budget; then
      log_error "Budget exceeded - pausing heartbeat checks"
      notify_slack "🚨 Heartbeat daemon paused due to budget limit"
      sleep 300  # Wait 5 minutes before rechecking
      continue
    fi

    # Release stale claims
    release_stale_claims

    # Check for CI failure loops
    check_ci_failures

    # Log status
    local in_progress
    in_progress=$(jq -r '[.features[] | select(.status == "in_progress")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    local pending
    pending=$(jq -r '[.features[] | select(.status == "pending")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    local completed
    completed=$(jq -r '[.features[] | select(.status == "completed")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    local blocked
    blocked=$(jq -r '[.features[] | select(.status == "blocked")] | length' "$PRD_FILE" 2>/dev/null || echo 0)

    log_debug "Status: $completed completed, $in_progress in-progress, $pending pending, $blocked blocked"
  done
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-daemon}" in
    daemon)
      run_heartbeat_daemon
      ;;
    check)
      release_stale_claims
      check_ci_failures
      ;;
    touch)
      touch_heartbeat "$2"
      ;;
    alive)
      if is_agent_alive "$2"; then
        echo "ALIVE"
      else
        echo "STALE"
        exit 1
      fi
      ;;
    help|*)
      echo "Usage: $0 {daemon|check|touch|alive}"
      echo ""
      echo "Commands:"
      echo "  daemon           - Run continuous heartbeat monitoring"
      echo "  check            - One-time check for stale claims"
      echo "  touch <agent>    - Update heartbeat for an agent"
      echo "  alive <agent>    - Check if an agent is alive"
      ;;
  esac
fi
