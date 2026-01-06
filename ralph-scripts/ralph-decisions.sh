#!/usr/bin/env bash
# ralph-decisions.sh - Decision queue for async human input
# Agents park decisions here, humans respond via Slack, agents continue
#
# Flow:
#   1. Agent calls await_decision() when blocked
#   2. Decision queued and sent to Slack
#   3. Human responds via Slack button/text
#   4. Decision file updated with answer
#   5. Agent unblocks and continues

set -euo pipefail

# Only source config if not already sourced
if [[ -z "${RALPH_DIR:-}" ]]; then
  source "$(dirname "$0")/ralph-config.sh"
fi

source "$(dirname "$0")/ralph-notify.sh"

# =============================================================================
# DECISION CONFIGURATION
# =============================================================================

DECISION_DIR="${PROGRESS_DIR}/decisions"
DECISION_LOG="${PROGRESS_DIR}/decisions.log"

mkdir -p "$DECISION_DIR"

# Default timeout for decisions (1 hour)
DEFAULT_TIMEOUT=3600

# =============================================================================
# DECISION FUNCTIONS
# =============================================================================

# Generate unique decision ID
generate_decision_id() {
  echo "dec-$(date +%s)-$$-$RANDOM"
}

# Log decision event
log_decision() {
  echo "$(date -Iseconds) $1" >> "$DECISION_LOG"
}

# Create a decision request
# Returns: decision_id
create_decision() {
  local question="$1"
  local options="$2"          # Comma-separated options
  local context="${3:-}"      # Additional context
  local timeout="${4:-$DEFAULT_TIMEOUT}"
  local default="${5:-}"      # Default if timeout
  local agent_id="${6:-${AGENT_ID:-unknown}}"
  local feature_id="${7:-${FEATURE_ID:-unknown}}"

  local decision_id=$(generate_decision_id)
  local decision_file="$DECISION_DIR/${decision_id}.json"

  # Convert options to JSON array
  local options_json=$(echo "$options" | tr ',' '\n' | while read opt; do
    opt=$(echo "$opt" | xargs)  # Trim
    echo "\"$opt\""
  done | paste -sd ',' -)

  cat > "$decision_file" << EOF
{
  "id": "$decision_id",
  "question": "$question",
  "options": [$options_json],
  "context": "$context",
  "default": "$default",
  "timeout": $timeout,
  "agent_id": "$agent_id",
  "feature_id": "$feature_id",
  "status": "pending",
  "answer": null,
  "created_at": "$(date -Iseconds)",
  "answered_at": null,
  "answered_by": null
}
EOF

  log_decision "CREATED $decision_id: $question (options: $options)"
  echo "$decision_id"
}

# Wait for a decision to be answered
# Usage: await_decision <question> <options> [context] [timeout] [default]
# Returns: The chosen option
await_decision() {
  local question="$1"
  local options="$2"
  local context="${3:-}"
  local timeout="${4:-$DEFAULT_TIMEOUT}"
  local default="${5:-}"

  # Create the decision
  local decision_id=$(create_decision "$question" "$options" "$context" "$timeout" "$default")
  local decision_file="$DECISION_DIR/${decision_id}.json"

  # Notify via Slack
  notify_decision_needed "$decision_id" "$question" "$options" "$context" "${AGENT_ID:-}"

  log_decision "WAITING $decision_id (timeout: ${timeout}s)"

  # Wait for answer
  local waited=0
  local poll_interval=5

  while [[ $waited -lt $timeout ]]; do
    # Check if answered
    local status=$(jq -r '.status' "$decision_file" 2>/dev/null || echo "pending")

    if [[ "$status" == "answered" ]]; then
      local answer=$(jq -r '.answer' "$decision_file")
      log_decision "ANSWERED $decision_id: $answer"
      echo "$answer"
      return 0
    fi

    if [[ "$status" == "cancelled" ]]; then
      log_decision "CANCELLED $decision_id"
      return 1
    fi

    sleep $poll_interval
    waited=$((waited + poll_interval))

    # Log progress every minute
    if [[ $((waited % 60)) -eq 0 ]]; then
      log_decision "WAITING $decision_id (${waited}s / ${timeout}s)"
    fi
  done

  # Timeout reached
  log_decision "TIMEOUT $decision_id after ${timeout}s"

  if [[ -n "$default" ]]; then
    # Use default
    jq --arg answer "$default" \
       '.status = "timeout" | .answer = $answer | .answered_at = (now | todate) | .answered_by = "timeout_default"' \
       "$decision_file" > "${decision_file}.tmp" && mv "${decision_file}.tmp" "$decision_file"

    log_decision "DEFAULT $decision_id: $default"
    echo "$default"
    return 0
  else
    # No default, mark as expired
    jq '.status = "expired"' "$decision_file" > "${decision_file}.tmp" && mv "${decision_file}.tmp" "$decision_file"
    return 2
  fi
}

# Answer a decision (called by Slack handler)
answer_decision() {
  local decision_id="$1"
  local answer="$2"
  local answered_by="${3:-slack}"

  local decision_file="$DECISION_DIR/${decision_id}.json"

  if [[ ! -f "$decision_file" ]]; then
    log_decision "ERROR: Decision $decision_id not found"
    return 1
  fi

  local status=$(jq -r '.status' "$decision_file")
  if [[ "$status" != "pending" ]]; then
    log_decision "ERROR: Decision $decision_id already $status"
    return 1
  fi

  # Validate answer is in options
  local valid=$(jq --arg answer "$answer" '.options | index($answer) != null' "$decision_file")
  if [[ "$valid" != "true" ]]; then
    log_decision "ERROR: Invalid answer '$answer' for $decision_id"
    return 1
  fi

  # Update decision
  jq --arg answer "$answer" \
     --arg by "$answered_by" \
     '.status = "answered" | .answer = $answer | .answered_at = (now | todate) | .answered_by = $by' \
     "$decision_file" > "${decision_file}.tmp" && mv "${decision_file}.tmp" "$decision_file"

  log_decision "ANSWERED $decision_id: $answer (by: $answered_by)"
  return 0
}

# Cancel a pending decision
cancel_decision() {
  local decision_id="$1"
  local reason="${2:-cancelled by user}"

  local decision_file="$DECISION_DIR/${decision_id}.json"

  if [[ ! -f "$decision_file" ]]; then
    return 1
  fi

  jq --arg reason "$reason" \
     '.status = "cancelled" | .cancel_reason = $reason | .cancelled_at = (now | todate)' \
     "$decision_file" > "${decision_file}.tmp" && mv "${decision_file}.tmp" "$decision_file"

  log_decision "CANCELLED $decision_id: $reason"
}

# Get pending decisions
get_pending_decisions() {
  echo "=== Pending Decisions ==="
  for df in "$DECISION_DIR"/*.json; do
    [[ -f "$df" ]] || continue

    local status=$(jq -r '.status' "$df")
    [[ "$status" != "pending" ]] && continue

    jq -r '"[\(.id)] \(.question) (options: \(.options | join(", ")))"' "$df"
  done
}

# Get decision status
get_decision() {
  local decision_id="$1"
  local decision_file="$DECISION_DIR/${decision_id}.json"

  if [[ -f "$decision_file" ]]; then
    cat "$decision_file"
  else
    echo "Decision not found: $decision_id"
    return 1
  fi
}

# List all decisions with status
list_decisions() {
  local filter="${1:-all}"  # all, pending, answered, timeout, cancelled

  echo "=== Decisions ($filter) ==="
  for df in "$DECISION_DIR"/*.json; do
    [[ -f "$df" ]] || continue

    local status=$(jq -r '.status' "$df")

    if [[ "$filter" != "all" && "$status" != "$filter" ]]; then
      continue
    fi

    jq -r '"[\(.status | ascii_upcase)] \(.id): \(.question) → \(.answer // "pending")"' "$df"
  done
}

# Clean up old decisions
cleanup_decisions() {
  local max_age="${1:-86400}"  # Default 24 hours
  local now=$(date +%s)

  for df in "$DECISION_DIR"/*.json; do
    [[ -f "$df" ]] || continue

    local created=$(jq -r '.created_at' "$df")
    local created_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${created%+*}" +%s 2>/dev/null || echo 0)
    local age=$((now - created_ts))

    if [[ $age -gt $max_age ]]; then
      local id=$(jq -r '.id' "$df")
      log_decision "CLEANUP $id (age: ${age}s)"
      rm -f "$df"
    fi
  done
}

# =============================================================================
# CONVENIENCE FUNCTIONS FOR COMMON DECISIONS
# =============================================================================

# Yes/No decision
ask_yes_no() {
  local question="$1"
  local default="${2:-}"
  local context="${3:-}"

  await_decision "$question" "Yes,No" "$context" 3600 "$default"
}

# Choose from preset options
ask_choice() {
  local question="$1"
  local options="$2"  # Comma-separated
  local default="${3:-}"
  local context="${4:-}"

  await_decision "$question" "$options" "$context" 3600 "$default"
}

# Approval request
ask_approval() {
  local item="$1"
  local context="${2:-}"

  await_decision "Approve $item?" "Approve,Reject,Defer" "$context" 7200 "Defer"
}

# Continue or abort
ask_continue() {
  local situation="$1"
  local context="${2:-}"

  await_decision "$situation Continue?" "Continue,Abort,Pause" "$context" 1800 "Continue"
}

# =============================================================================
# CLI
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-help}" in
    create)
      # create <question> <options> [context] [timeout] [default]
      create_decision "$2" "$3" "${4:-}" "${5:-3600}" "${6:-}"
      ;;
    await)
      # await <question> <options> [context] [timeout] [default]
      await_decision "$2" "$3" "${4:-}" "${5:-3600}" "${6:-}"
      ;;
    answer)
      # answer <decision_id> <answer> [answered_by]
      answer_decision "$2" "$3" "${4:-cli}"
      echo "Decision $2 answered: $3"
      ;;
    cancel)
      # cancel <decision_id> [reason]
      cancel_decision "$2" "${3:-cancelled via CLI}"
      echo "Decision $2 cancelled"
      ;;
    get)
      # get <decision_id>
      get_decision "$2"
      ;;
    list)
      # list [filter]
      list_decisions "${2:-all}"
      ;;
    pending)
      get_pending_decisions
      ;;
    cleanup)
      cleanup_decisions "${2:-86400}"
      echo "Cleanup complete"
      ;;
    yes-no)
      # yes-no <question> [default] [context]
      ask_yes_no "$2" "${3:-}" "${4:-}"
      ;;
    choice)
      # choice <question> <options> [default] [context]
      ask_choice "$2" "$3" "${4:-}" "${5:-}"
      ;;
    approval)
      # approval <item> [context]
      ask_approval "$2" "${3:-}"
      ;;
    help|*)
      echo "Usage: $0 <command> [args...]"
      echo ""
      echo "Commands:"
      echo "  create <question> <options> [context] [timeout] [default]"
      echo "         Create decision request (non-blocking)"
      echo ""
      echo "  await <question> <options> [context] [timeout] [default]"
      echo "         Create and wait for decision (blocking)"
      echo ""
      echo "  answer <decision_id> <answer> [answered_by]"
      echo "         Answer a pending decision"
      echo ""
      echo "  cancel <decision_id> [reason]"
      echo "         Cancel a pending decision"
      echo ""
      echo "  get <decision_id>     - Get decision details"
      echo "  list [filter]         - List decisions (all|pending|answered|timeout)"
      echo "  pending               - Show pending decisions"
      echo "  cleanup [max_age]     - Remove old decisions"
      echo ""
      echo "Convenience commands:"
      echo "  yes-no <question> [default] [context]"
      echo "  choice <question> <options> [default] [context]"
      echo "  approval <item> [context]"
      echo ""
      echo "Examples:"
      echo "  $0 await 'Which database?' 'PostgreSQL,MySQL,SQLite' '' 3600 'PostgreSQL'"
      echo "  $0 answer dec-123456 'PostgreSQL' 'slack_user'"
      echo "  $0 yes-no 'Enable caching?' 'Yes'"
      ;;
  esac
fi

# Export functions for sourcing
export -f create_decision await_decision answer_decision cancel_decision get_decision get_pending_decisions list_decisions ask_yes_no ask_choice ask_approval ask_continue
