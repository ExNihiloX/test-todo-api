#!/usr/bin/env bash
# ralph-slack-listener.sh - Daemon that listens for Slack responses
# Runs alongside Ralph to receive human input from Slack
#
# Two modes:
#   1. Polling mode: Periodically checks for new messages (simple, works everywhere)
#   2. Server mode: HTTP server for Slack interactive webhooks (requires ngrok or public URL)

set -euo pipefail

# Only source config if not already sourced
if [[ -z "${RALPH_DIR:-}" ]]; then
  source "$(dirname "$0")/ralph-config.sh"
fi

source "$(dirname "$0")/ralph-slack.sh"
source "$(dirname "$0")/ralph-decisions.sh"
source "$(dirname "$0")/ralph-notify.sh"

# =============================================================================
# LISTENER CONFIGURATION
# =============================================================================

LISTENER_LOG="${PROGRESS_DIR}/slack-listener.log"
LISTENER_PID_FILE="${PROGRESS_DIR}/slack-listener.pid"
POLL_INTERVAL="${SLACK_POLL_INTERVAL:-10}"
HTTP_PORT="${SLACK_HTTP_PORT:-3000}"

# =============================================================================
# LOGGING
# =============================================================================

listener_log() {
  echo "$(date -Iseconds) $1" | tee -a "$LISTENER_LOG" >&2
}

# =============================================================================
# MESSAGE PARSING
# =============================================================================

# Parse and route incoming message
route_message() {
  local text="$1"
  local user="${2:-unknown}"
  local channel="${3:-}"
  local thread_ts="${4:-}"

  listener_log "ROUTE: '$text' from $user"

  # Normalize text (lowercase, trim)
  local cmd=$(echo "$text" | tr '[:upper:]' '[:lower:]' | xargs)

  case "$cmd" in
    # Status commands
    status|/status|"how's it going"|"how is it going")
      send_status_response "$channel" "$thread_ts"
      ;;

    # Control commands
    pause|/pause|stop)
      pause_ralph
      send_message ":pause_button: Ralph paused. Reply \`resume\` to continue." "$channel"
      ;;

    resume|/resume|continue|go)
      resume_ralph
      send_message ":arrow_forward: Ralph resumed!" "$channel"
      ;;

    abort|/abort|kill|quit)
      abort_ralph
      send_message ":stop_sign: Ralph is shutting down..." "$channel"
      ;;

    # Decision commands
    decisions|/decisions|pending)
      send_pending_decisions "$channel"
      ;;

    # Help
    help|/help|"?"|commands)
      send_help "$channel"
      ;;

    # Check for decision answer format: "dec-123456 Answer"
    dec-*)
      handle_decision_text "$text" "$user" "$channel" "$thread_ts"
      ;;

    # Check for numbered answer: "1" or "2" etc (for most recent decision)
    [1-9])
      handle_numbered_answer "$text" "$user" "$channel" "$thread_ts"
      ;;

    # PR approval shortcuts
    "approve all"|"approve")
      approve_pending_prs "$channel"
      ;;

    "review")
      show_pending_prs "$channel"
      ;;

    # Unknown - might be conversational
    *)
      # Don't respond to everything, just log it
      listener_log "IGNORED: $text"
      ;;
  esac
}

# =============================================================================
# RESPONSE HANDLERS
# =============================================================================

send_status_response() {
  local channel="$1"
  local thread_ts="${2:-}"

  # Get current stats from state
  local completed=0 in_progress=0 pending=0 blocked=0 total=0

  if [[ -f "$STATE_FILE" ]]; then
    completed=$(jq '[.features[] | select(.status == "completed")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    in_progress=$(jq '[.features[] | select(.status == "in_progress")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    pending=$(jq '[.features[] | select(.status == "pending")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    blocked=$(jq '[.features[] | select(.status == "blocked")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    total=$(jq '.features | length' "$STATE_FILE" 2>/dev/null || echo 0)
  fi

  # Get cost
  local cost="0.00"
  if [[ -f "${PROGRESS_DIR}/cost.log" ]]; then
    cost=$(awk -F',' '{sum += $6} END {printf "%.2f", sum}' "${PROGRESS_DIR}/cost.log" 2>/dev/null || echo "0.00")
  fi

  # Check if paused
  local status_emoji=":green_circle:"
  [[ -f "$PROGRESS_DIR/.paused" ]] && status_emoji=":yellow_circle: PAUSED"
  [[ -f "$PROGRESS_DIR/.abort" ]] && status_emoji=":red_circle: STOPPING"

  notify_progress_summary "$completed" "$in_progress" "$pending" "$blocked" "$total" "$cost" ""
}

send_pending_decisions() {
  local channel="$1"

  local decisions=""
  local count=0

  for df in "$DECISION_DIR"/*.json; do
    [[ -f "$df" ]] || continue

    local status=$(jq -r '.status' "$df")
    [[ "$status" != "pending" ]] && continue

    count=$((count + 1))
    local id=$(jq -r '.id' "$df")
    local question=$(jq -r '.question' "$df")
    local options=$(jq -r '.options | join(", ")' "$df")

    decisions+="\n*$count.* $question\n    Options: $options\n    ID: \`$id\`\n"
  done

  if [[ $count -eq 0 ]]; then
    send_message ":white_check_mark: No pending decisions!" "$channel"
  else
    send_message ":question: *Pending Decisions ($count):*$decisions\nReply with number (e.g., \`1\`) and your choice, or \`<id> <choice>\`" "$channel"
  fi
}

send_help() {
  local channel="$1"

  local help_text=":robot_face: *Ralph Commands*

*Status:*
\`status\` - Show current progress

*Control:*
\`pause\` - Pause all agents
\`resume\` - Resume agents
\`abort\` - Stop Ralph

*Decisions:*
\`decisions\` - Show pending decisions
\`1\` / \`2\` / etc - Quick answer to most recent decision
\`dec-123456 Answer\` - Answer specific decision

*PRs:*
\`review\` - Show pending PRs
\`approve\` - Approve all pending PRs

*Other:*
\`help\` - Show this message"

  send_message "$help_text" "$channel"
}

handle_decision_text() {
  local text="$1"
  local user="$2"
  local channel="$3"
  local thread_ts="${4:-}"

  # Parse: "dec-123456 Answer" or "dec-123456:Answer"
  local decision_id=$(echo "$text" | grep -oE 'dec-[0-9]+' | head -1)
  local answer=$(echo "$text" | sed "s/$decision_id[: ]*//" | xargs)

  if [[ -z "$answer" ]]; then
    send_message ":x: Please include your answer: \`$decision_id <your choice>\`" "$channel"
    return
  fi

  if answer_decision "$decision_id" "$answer" "$user"; then
    send_message ":white_check_mark: Got it! Using *$answer* for $decision_id" "$channel"
  else
    send_message ":x: Couldn't process that. Check the decision ID and answer." "$channel"
  fi
}

handle_numbered_answer() {
  local number="$1"
  local user="$2"
  local channel="$3"
  local thread_ts="${4:-}"

  # Find the nth pending decision
  local count=0
  local target_file=""

  for df in "$DECISION_DIR"/*.json; do
    [[ -f "$df" ]] || continue

    local status=$(jq -r '.status' "$df")
    [[ "$status" != "pending" ]] && continue

    count=$((count + 1))
    if [[ $count -eq $number ]]; then
      target_file="$df"
      break
    fi
  done

  if [[ -z "$target_file" ]]; then
    send_message ":x: No decision #$number found. Use \`decisions\` to see pending." "$channel"
    return
  fi

  # Show options and ask for choice
  local decision_id=$(jq -r '.id' "$target_file")
  local question=$(jq -r '.question' "$target_file")
  local options=$(jq -r '.options | to_entries | map("\(.key + 1). \(.value)") | join("\n")' "$target_file")

  send_message "*$question*\n\n$options\n\nReply with: \`$decision_id <your choice>\`" "$channel"
}

# =============================================================================
# CONTROL FUNCTIONS
# =============================================================================

pause_ralph() {
  touch "$PROGRESS_DIR/.paused"
  listener_log "PAUSE requested"
}

resume_ralph() {
  rm -f "$PROGRESS_DIR/.paused"
  listener_log "RESUME requested"
}

abort_ralph() {
  touch "$PROGRESS_DIR/.abort"
  listener_log "ABORT requested"
}

approve_pending_prs() {
  local channel="$1"
  # TODO: Implement PR approval
  send_message ":construction: PR approval not yet implemented" "$channel"
}

show_pending_prs() {
  local channel="$1"

  # Get PRs from state
  local prs=""
  if [[ -f "$STATE_FILE" ]]; then
    prs=$(jq -r '.features[] | select(.status == "completed") | select(.pr_url != null) | "• \(.name): \(.pr_url)"' "$STATE_FILE" 2>/dev/null || echo "")
  fi

  if [[ -z "$prs" ]]; then
    send_message ":white_check_mark: No pending PRs" "$channel"
  else
    send_message "*Pending PRs:*\n$prs" "$channel"
  fi
}

# =============================================================================
# POLLING MODE
# =============================================================================

run_polling_listener() {
  listener_log "Starting polling listener (interval: ${POLL_INTERVAL}s)"

  # Save PID
  echo $$ > "$LISTENER_PID_FILE"

  # Track last seen message
  local last_ts=""

  while true; do
    # Check for abort
    if [[ -f "$PROGRESS_DIR/.abort" ]]; then
      listener_log "Abort signal received, stopping"
      break
    fi

    # Poll Slack for new messages
    if [[ "$(get_slack_mode)" == "bot" ]]; then
      local channel_id=$(get_channel_id "${SLACK_CHANNEL#\#}")

      local url="$SLACK_API/conversations.history?channel=$channel_id&limit=10"
      [[ -n "$last_ts" ]] && url+="&oldest=$last_ts"

      local response=$(curl -s -X GET "$url" -H "Authorization: Bearer $SLACK_BOT_TOKEN" 2>/dev/null || echo "{}")

      # Process messages (newest first, so reverse)
      echo "$response" | jq -c '.messages[]?' 2>/dev/null | tac | while read -r msg; do
        local subtype=$(echo "$msg" | jq -r '.subtype // empty')
        [[ "$subtype" == "bot_message" ]] && continue
        [[ -n "$subtype" ]] && continue

        local text=$(echo "$msg" | jq -r '.text')
        local user=$(echo "$msg" | jq -r '.user')
        local ts=$(echo "$msg" | jq -r '.ts')
        local thread_ts=$(echo "$msg" | jq -r '.thread_ts // empty')

        # Skip if we've seen this message
        [[ "$ts" == "$last_ts" ]] && continue

        route_message "$text" "$user" "$SLACK_CHANNEL" "$thread_ts"
      done

      # Update last timestamp
      local new_ts=$(echo "$response" | jq -r '.messages[0].ts // empty' 2>/dev/null)
      [[ -n "$new_ts" ]] && last_ts="$new_ts"
    fi

    # Also check for interaction files (from webhook receiver)
    for f in "$SLACK_RESPONSE_DIR"/interaction_*.json; do
      [[ -f "$f" ]] || continue

      local payload=$(cat "$f")
      handle_interaction "$payload"
      rm -f "$f"
    done

    sleep "$POLL_INTERVAL"
  done

  rm -f "$LISTENER_PID_FILE"
  listener_log "Polling listener stopped"
}

# =============================================================================
# HTTP SERVER MODE (for Slack Interactive Webhooks)
# =============================================================================

# Simple HTTP server using netcat (for receiving Slack webhooks)
run_http_listener() {
  listener_log "Starting HTTP listener on port $HTTP_PORT"
  listener_log "Configure Slack Interactivity URL: http://your-server:$HTTP_PORT/slack/interactions"

  echo $$ > "$LISTENER_PID_FILE"

  while true; do
    # Check for abort
    [[ -f "$PROGRESS_DIR/.abort" ]] && break

    # Listen for single request
    {
      # Read request
      read -r request_line
      listener_log "HTTP: $request_line"

      # Read headers
      while read -r header; do
        [[ "$header" == $'\r' ]] && break
      done

      # Read body (Content-Length based)
      local body=""
      if [[ "$request_line" == *"POST"* ]]; then
        # Simple: read remaining input
        read -t 1 body || true
      fi

      # Route request
      if [[ "$request_line" == *"/slack/interactions"* ]]; then
        # URL decode and parse payload
        local payload=$(echo "$body" | sed 's/payload=//' | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))" 2>/dev/null || echo "$body")

        local response=$(handle_interaction "$payload")

        # Send response
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#response}\r\n\r\n$response"
      elif [[ "$request_line" == *"/health"* ]]; then
        echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
      else
        echo -e "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found"
      fi
    } | nc -l "$HTTP_PORT" -q 1 2>/dev/null || true
  done

  rm -f "$LISTENER_PID_FILE"
  listener_log "HTTP listener stopped"
}

# =============================================================================
# DAEMON MANAGEMENT
# =============================================================================

start_listener() {
  local mode="${1:-poll}"

  if [[ -f "$LISTENER_PID_FILE" ]]; then
    local pid=$(cat "$LISTENER_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Listener already running (PID: $pid)"
      return 1
    fi
  fi

  case "$mode" in
    poll)
      run_polling_listener &
      ;;
    http)
      run_http_listener &
      ;;
  esac

  echo "Listener started (mode: $mode, PID: $!)"
}

stop_listener() {
  if [[ -f "$LISTENER_PID_FILE" ]]; then
    local pid=$(cat "$LISTENER_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      rm -f "$LISTENER_PID_FILE"
      echo "Listener stopped"
    else
      rm -f "$LISTENER_PID_FILE"
      echo "Listener was not running"
    fi
  else
    echo "No listener PID file found"
  fi
}

listener_status() {
  if [[ -f "$LISTENER_PID_FILE" ]]; then
    local pid=$(cat "$LISTENER_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Listener running (PID: $pid)"
      return 0
    fi
  fi
  echo "Listener not running"
  return 1
}

# =============================================================================
# CLI
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-help}" in
    start)
      start_listener "${2:-poll}"
      ;;
    stop)
      stop_listener
      ;;
    status)
      listener_status
      ;;
    poll)
      run_polling_listener
      ;;
    http)
      run_http_listener
      ;;
    test)
      # Test message routing
      route_message "${2:-status}" "test_user" "$SLACK_CHANNEL"
      ;;
    help|*)
      echo "Usage: $0 <command> [args...]"
      echo ""
      echo "Daemon commands:"
      echo "  start [poll|http]  - Start listener in background"
      echo "  stop               - Stop listener"
      echo "  status             - Check if listener is running"
      echo ""
      echo "Direct commands:"
      echo "  poll               - Run polling listener (foreground)"
      echo "  http               - Run HTTP listener (foreground)"
      echo "  test <message>     - Test message routing"
      echo ""
      echo "Environment:"
      echo "  SLACK_POLL_INTERVAL  - Seconds between polls (default: 10)"
      echo "  SLACK_HTTP_PORT      - Port for HTTP listener (default: 3000)"
      echo ""
      echo "Modes:"
      echo "  poll - Polls Slack API for messages (works anywhere, needs bot token)"
      echo "  http - HTTP server for Slack webhooks (needs public URL/ngrok)"
      ;;
  esac
fi
