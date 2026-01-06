#!/usr/bin/env bash
# ralph-slack.sh - Slack integration utilities
# Handles both outbound (sending) and inbound (receiving) Slack communication
#
# Supports two modes:
#   1. Webhook mode (simple, outbound only): Set SLACK_WEBHOOK_URL
#   2. Bot mode (full, bidirectional): Set SLACK_BOT_TOKEN + SLACK_APP_TOKEN

set -euo pipefail

# Only source config if not already sourced
if [[ -z "${RALPH_DIR:-}" ]]; then
  source "$(dirname "$0")/ralph-config.sh"
fi

# =============================================================================
# SLACK CONFIGURATION
# =============================================================================

SLACK_LOG="${PROGRESS_DIR}/slack.log"
SLACK_CHANNEL="${SLACK_CHANNEL:-#ralph-updates}"
SLACK_API="https://slack.com/api"

# Polling file for responses (alternative to Socket Mode)
SLACK_RESPONSE_DIR="${PROGRESS_DIR}/slack_responses"
mkdir -p "$SLACK_RESPONSE_DIR"

# =============================================================================
# LOGGING
# =============================================================================

log_slack() {
  echo "$(date -Iseconds) $1" >> "$SLACK_LOG"
}

# =============================================================================
# CONNECTION CHECK
# =============================================================================

# Check if Slack is configured
is_slack_configured() {
  [[ -n "${SLACK_WEBHOOK_URL:-}" || -n "${SLACK_BOT_TOKEN:-}" ]]
}

# Check connection mode
get_slack_mode() {
  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    echo "bot"
  elif [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "webhook"
  else
    echo "none"
  fi
}

# Test Slack connection
test_connection() {
  local mode=$(get_slack_mode)

  case "$mode" in
    bot)
      local response=$(curl -s -X POST "$SLACK_API/auth.test" \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json")

      if echo "$response" | jq -e '.ok' > /dev/null 2>&1; then
        local team=$(echo "$response" | jq -r '.team')
        local user=$(echo "$response" | jq -r '.user')
        echo "Connected as @$user in $team workspace (bot mode)"
        return 0
      else
        echo "Connection failed: $(echo "$response" | jq -r '.error')"
        return 1
      fi
      ;;
    webhook)
      echo "Webhook mode (outbound only) - send a test message to verify"
      return 0
      ;;
    none)
      echo "Slack not configured. Set SLACK_WEBHOOK_URL or SLACK_BOT_TOKEN"
      return 1
      ;;
  esac
}

# =============================================================================
# OUTBOUND MESSAGES
# =============================================================================

# Send a message to Slack
send_message() {
  local text="$1"
  local channel="${2:-$SLACK_CHANNEL}"

  if ! is_slack_configured; then
    log_slack "SKIP (not configured): $text"
    echo "$text"
    return 0
  fi

  local mode=$(get_slack_mode)

  if [[ "$mode" == "bot" ]]; then
    local response=$(curl -s -X POST "$SLACK_API/chat.postMessage" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$channel\", \"text\": \"$text\"}")

    if echo "$response" | jq -e '.ok' > /dev/null 2>&1; then
      local ts=$(echo "$response" | jq -r '.ts')
      log_slack "SENT [$ts]: $text"
      echo "$ts"  # Return message timestamp (useful for threading)
    else
      log_slack "ERROR: $(echo "$response" | jq -r '.error')"
      return 1
    fi
  else
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$text\"}" > /dev/null
    log_slack "SENT (webhook): $text"
  fi
}

# Send blocks message
send_blocks() {
  local blocks="$1"
  local text="${2:-Ralph Update}"
  local channel="${3:-$SLACK_CHANNEL}"

  if ! is_slack_configured; then
    log_slack "SKIP (not configured): $text"
    return 0
  fi

  local mode=$(get_slack_mode)

  if [[ "$mode" == "bot" ]]; then
    local response=$(curl -s -X POST "$SLACK_API/chat.postMessage" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$channel\", \"text\": \"$text\", \"blocks\": $blocks}")

    if echo "$response" | jq -e '.ok' > /dev/null 2>&1; then
      log_slack "SENT BLOCKS: $text"
      echo "$response" | jq -r '.ts'
    else
      log_slack "ERROR: $(echo "$response" | jq -r '.error')"
      return 1
    fi
  else
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$text\", \"blocks\": $blocks}" > /dev/null
    log_slack "SENT BLOCKS (webhook): $text"
  fi
}

# Reply in thread
reply_in_thread() {
  local thread_ts="$1"
  local text="$2"
  local channel="${3:-$SLACK_CHANNEL}"

  if [[ "$(get_slack_mode)" != "bot" ]]; then
    log_slack "Threading requires bot mode"
    send_message "$text" "$channel"
    return
  fi

  curl -s -X POST "$SLACK_API/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"channel\": \"$channel\", \"text\": \"$text\", \"thread_ts\": \"$thread_ts\"}" > /dev/null

  log_slack "REPLIED in thread $thread_ts: $text"
}

# Update existing message
update_message() {
  local ts="$1"
  local text="$2"
  local channel="${3:-$SLACK_CHANNEL}"

  if [[ "$(get_slack_mode)" != "bot" ]]; then
    log_slack "Update requires bot mode"
    return 1
  fi

  curl -s -X POST "$SLACK_API/chat.update" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"channel\": \"$channel\", \"ts\": \"$ts\", \"text\": \"$text\"}" > /dev/null

  log_slack "UPDATED $ts: $text"
}

# =============================================================================
# INBOUND MESSAGES (Bot Mode Only)
# =============================================================================

# Get recent messages from channel
get_recent_messages() {
  local channel="${1:-$SLACK_CHANNEL}"
  local limit="${2:-10}"

  if [[ "$(get_slack_mode)" != "bot" ]]; then
    echo "Requires bot mode"
    return 1
  fi

  # Get channel ID if name provided
  local channel_id="$channel"
  if [[ "$channel" == "#"* ]]; then
    channel_id=$(get_channel_id "${channel#\#}")
  fi

  curl -s -X GET "$SLACK_API/conversations.history?channel=$channel_id&limit=$limit" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" | jq '.messages'
}

# Get channel ID from name
get_channel_id() {
  local channel_name="$1"

  local response=$(curl -s -X GET "$SLACK_API/conversations.list?types=public_channel,private_channel" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN")

  echo "$response" | jq -r --arg name "$channel_name" '.channels[] | select(.name == $name) | .id'
}

# Poll for new messages (simple alternative to Socket Mode)
poll_messages() {
  local channel="${1:-$SLACK_CHANNEL}"
  local since="${2:-}"  # Timestamp to get messages after
  local callback="${3:-handle_message}"  # Function to call for each message

  if [[ "$(get_slack_mode)" != "bot" ]]; then
    echo "Polling requires bot mode"
    return 1
  fi

  local channel_id=$(get_channel_id "${channel#\#}")

  local url="$SLACK_API/conversations.history?channel=$channel_id&limit=20"
  [[ -n "$since" ]] && url+="&oldest=$since"

  local response=$(curl -s -X GET "$url" -H "Authorization: Bearer $SLACK_BOT_TOKEN")

  echo "$response" | jq -c '.messages[]?' | while read -r msg; do
    local msg_type=$(echo "$msg" | jq -r '.type')
    local subtype=$(echo "$msg" | jq -r '.subtype // empty')

    # Skip bot messages and system messages
    [[ "$subtype" == "bot_message" ]] && continue
    [[ -n "$subtype" ]] && continue

    # Call handler
    $callback "$msg"
  done

  # Return latest timestamp for next poll
  echo "$response" | jq -r '.messages[0].ts // empty'
}

# Default message handler
handle_message() {
  local msg="$1"
  local text=$(echo "$msg" | jq -r '.text')
  local user=$(echo "$msg" | jq -r '.user')
  local ts=$(echo "$msg" | jq -r '.ts')

  log_slack "RECEIVED from $user: $text"

  # Parse commands
  case "$text" in
    status|/status)
      source "$(dirname "$0")/ralph-status.sh"
      send_message "$(get_status_summary)" "$SLACK_CHANNEL"
      ;;
    pause|/pause)
      touch "$PROGRESS_DIR/.paused"
      send_message ":pause_button: Ralph paused. Reply \`resume\` to continue." "$SLACK_CHANNEL"
      ;;
    resume|/resume)
      rm -f "$PROGRESS_DIR/.paused"
      send_message ":arrow_forward: Ralph resumed." "$SLACK_CHANNEL"
      ;;
    abort|/abort)
      touch "$PROGRESS_DIR/.abort"
      send_message ":stop_sign: Ralph aborting..." "$SLACK_CHANNEL"
      ;;
    help|/help)
      send_message "Commands: \`status\`, \`pause\`, \`resume\`, \`abort\`, \`decisions\`" "$SLACK_CHANNEL"
      ;;
    decisions|/decisions)
      source "$(dirname "$0")/ralph-decisions.sh"
      local pending=$(get_pending_decisions)
      send_message "$pending" "$SLACK_CHANNEL"
      ;;
    *)
      # Check if it's a decision answer
      if [[ "$text" =~ ^dec-[0-9]+ ]]; then
        # Format: dec-123456 answer
        local decision_id=$(echo "$text" | awk '{print $1}')
        local answer=$(echo "$text" | cut -d' ' -f2-)

        source "$(dirname "$0")/ralph-decisions.sh"
        if answer_decision "$decision_id" "$answer" "$user"; then
          reply_in_thread "$ts" ":white_check_mark: Got it! Using: *$answer*" "$SLACK_CHANNEL"
        else
          reply_in_thread "$ts" ":x: Couldn't process that answer" "$SLACK_CHANNEL"
        fi
      fi
      ;;
  esac
}

# =============================================================================
# INTERACTIVE ELEMENTS (Button Clicks)
# =============================================================================

# Handle interaction payload (from Slack interactivity)
# This would be called by a web server receiving Slack webhooks
handle_interaction() {
  local payload="$1"

  local action_id=$(echo "$payload" | jq -r '.actions[0].action_id')
  local action_value=$(echo "$payload" | jq -r '.actions[0].value')
  local user_id=$(echo "$payload" | jq -r '.user.id')
  local block_id=$(echo "$payload" | jq -r '.actions[0].block_id')

  log_slack "INTERACTION: $action_id = $action_value (by $user_id)"

  # Check if it's a decision response
  if [[ "$action_value" =~ ^dec- ]]; then
    # Format: dec-123456:Answer
    local decision_id="${action_value%%:*}"
    local answer="${action_value#*:}"

    source "$(dirname "$0")/ralph-decisions.sh"
    answer_decision "$decision_id" "$answer" "$user_id"

    # Acknowledge
    echo "{\"text\": \":white_check_mark: Using: $answer\"}"
    return
  fi

  # Handle other action types
  case "$action_id" in
    approve)
      local feature_id="${action_value#approve_}"
      log_slack "PR APPROVED: $feature_id"
      # TODO: Trigger merge
      echo "{\"text\": \":white_check_mark: PR approved!\"}"
      ;;
    defer)
      local feature_id="${action_value#defer_}"
      log_slack "PR DEFERRED: $feature_id"
      echo "{\"text\": \":hourglass: Will review later\"}"
      ;;
    review_prs)
      # TODO: Show pending PRs
      echo "{\"text\": \"Fetching pending PRs...\"}"
      ;;
    *)
      echo "{\"text\": \"Action received: $action_id\"}"
      ;;
  esac
}

# Write interaction to file (for polling-based handling)
record_interaction() {
  local payload="$1"
  local timestamp=$(date +%s%N)
  echo "$payload" > "$SLACK_RESPONSE_DIR/interaction_${timestamp}.json"
}

# Process pending interactions
process_interactions() {
  for f in "$SLACK_RESPONSE_DIR"/interaction_*.json; do
    [[ -f "$f" ]] || continue

    local payload=$(cat "$f")
    handle_interaction "$payload"
    rm -f "$f"
  done
}

# =============================================================================
# POLLING DAEMON
# =============================================================================

# Run polling daemon (alternative to Socket Mode)
run_poll_daemon() {
  local interval="${1:-10}"  # Poll every 10 seconds

  log_slack "Starting poll daemon (interval: ${interval}s)"

  local last_ts=""

  while true; do
    # Check for abort
    [[ -f "$PROGRESS_DIR/.abort" ]] && break

    # Poll for new messages
    if [[ "$(get_slack_mode)" == "bot" ]]; then
      local new_ts=$(poll_messages "$SLACK_CHANNEL" "$last_ts" "handle_message")
      [[ -n "$new_ts" ]] && last_ts="$new_ts"
    fi

    # Process any recorded interactions
    process_interactions

    sleep "$interval"
  done

  log_slack "Poll daemon stopped"
}

# =============================================================================
# CLI
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-help}" in
    test)
      test_connection
      ;;
    mode)
      echo "Mode: $(get_slack_mode)"
      ;;
    send)
      send_message "$2" "${3:-$SLACK_CHANNEL}"
      ;;
    blocks)
      send_blocks "$2" "${3:-Update}" "${4:-$SLACK_CHANNEL}"
      ;;
    reply)
      reply_in_thread "$2" "$3" "${4:-$SLACK_CHANNEL}"
      ;;
    update)
      update_message "$2" "$3" "${4:-$SLACK_CHANNEL}"
      ;;
    history)
      get_recent_messages "${2:-$SLACK_CHANNEL}" "${3:-10}"
      ;;
    poll)
      run_poll_daemon "${2:-10}"
      ;;
    interact)
      handle_interaction "$2"
      ;;
    help|*)
      echo "Usage: $0 <command> [args...]"
      echo ""
      echo "Connection:"
      echo "  test                     - Test Slack connection"
      echo "  mode                     - Show current mode (bot/webhook/none)"
      echo ""
      echo "Outbound:"
      echo "  send <text> [channel]    - Send text message"
      echo "  blocks <json> [text] [channel] - Send Block Kit message"
      echo "  reply <thread_ts> <text> [channel] - Reply in thread"
      echo "  update <ts> <text> [channel] - Update message"
      echo ""
      echo "Inbound (bot mode only):"
      echo "  history [channel] [limit] - Get recent messages"
      echo "  poll [interval]          - Start polling daemon"
      echo "  interact <payload>       - Handle interaction payload"
      echo ""
      echo "Environment:"
      echo "  SLACK_WEBHOOK_URL  - For webhook mode (outbound only)"
      echo "  SLACK_BOT_TOKEN    - For bot mode (bidirectional)"
      echo "  SLACK_CHANNEL      - Default channel (default: #ralph-updates)"
      ;;
  esac
fi

# Export functions for sourcing
export -f is_slack_configured get_slack_mode send_message send_blocks reply_in_thread update_message handle_message handle_interaction
