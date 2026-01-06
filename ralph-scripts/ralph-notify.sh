#!/usr/bin/env bash
# ralph-notify.sh - Rich Slack notifications for Ralph
# Sends formatted messages with Block Kit for better UX
#
# Requires: SLACK_WEBHOOK_URL or SLACK_BOT_TOKEN environment variable

set -euo pipefail

# Only source config if not already sourced
if [[ -z "${RALPH_DIR:-}" ]]; then
  source "$(dirname "$0")/ralph-config.sh"
fi

# =============================================================================
# NOTIFICATION CONFIGURATION
# =============================================================================

NOTIFY_LOG="${PROGRESS_DIR}/notifications.log"
SLACK_CHANNEL="${SLACK_CHANNEL:-#ralph-updates}"

# =============================================================================
# CORE NOTIFICATION FUNCTIONS
# =============================================================================

# Log notification
log_notify() {
  echo "$(date -Iseconds) $1" >> "$NOTIFY_LOG"
}

# Send simple text message
send_slack_text() {
  local text="$1"

  if [[ -z "${SLACK_WEBHOOK_URL:-}" && -z "${SLACK_BOT_TOKEN:-}" ]]; then
    log_notify "SKIP (no Slack configured): $text"
    echo "$text"  # Echo locally if no Slack
    return 0
  fi

  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    # Use Bot API (preferred)
    curl -s -X POST "https://slack.com/api/chat.postMessage" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$SLACK_CHANNEL\", \"text\": \"$text\"}" > /dev/null
  else
    # Use webhook (simpler)
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$text\"}" > /dev/null
  fi

  log_notify "SENT: $text"
}

# Send rich Block Kit message
send_slack_blocks() {
  local blocks="$1"
  local text="${2:-Ralph Update}"  # Fallback text for notifications

  if [[ -z "${SLACK_WEBHOOK_URL:-}" && -z "${SLACK_BOT_TOKEN:-}" ]]; then
    log_notify "SKIP (no Slack configured): $text"
    return 0
  fi

  local payload="{\"text\": \"$text\", \"blocks\": $blocks}"

  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    curl -s -X POST "https://slack.com/api/chat.postMessage" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$SLACK_CHANNEL\", $payload}" > /dev/null
  else
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$payload" > /dev/null
  fi

  log_notify "SENT BLOCKS: $text"
}

# =============================================================================
# NOTIFICATION TYPES
# =============================================================================

# Ralph system started
notify_start() {
  local agent_count="${1:-3}"
  local mode="${2:-flat}"

  local blocks=$(cat <<EOF
[
  {
    "type": "header",
    "text": {"type": "plain_text", "text": "Ralph Started", "emoji": true}
  },
  {
    "type": "section",
    "fields": [
      {"type": "mrkdwn", "text": "*Agents:* $agent_count"},
      {"type": "mrkdwn", "text": "*Mode:* $mode"}
    ]
  },
  {
    "type": "context",
    "elements": [
      {"type": "mrkdwn", "text": "Updates will appear here. Reply with \`status\` anytime."}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "Ralph started with $agent_count agents"
}

# Feature work started
notify_feature_started() {
  local feature_id="$1"
  local feature_name="$2"
  local agent_id="$3"

  send_slack_text ":rocket: *$agent_id* started: $feature_name ($feature_id)"
}

# Feature completed
notify_feature_completed() {
  local feature_id="$1"
  local feature_name="$2"
  local pr_url="${3:-}"
  local files_changed="${4:-}"
  local tests_passed="${5:-}"

  local blocks=$(cat <<EOF
[
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": ":white_check_mark: *Feature Complete*\n*$feature_name* ($feature_id)"}
  },
  {
    "type": "section",
    "fields": [
      {"type": "mrkdwn", "text": "*Files Changed:* $files_changed"},
      {"type": "mrkdwn", "text": "*Tests:* $tests_passed"}
    ]
  },
  {
    "type": "actions",
    "block_id": "pr_${feature_id}",
    "elements": [
      {"type": "button", "text": {"type": "plain_text", "text": "View PR"}, "url": "$pr_url"},
      {"type": "button", "text": {"type": "plain_text", "text": "Approve"}, "value": "approve_${feature_id}", "action_id": "approve", "style": "primary"},
      {"type": "button", "text": {"type": "plain_text", "text": "Review Later"}, "value": "defer_${feature_id}", "action_id": "defer"}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "Feature complete: $feature_name"
}

# Feature blocked
notify_blocked() {
  local feature_id="$1"
  local reason="$2"
  local agent_id="${3:-}"

  local blocks=$(cat <<EOF
[
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": ":no_entry: *Blocked*\n*Feature:* $feature_id\n*Reason:* $reason"}
  },
  {
    "type": "context",
    "elements": [
      {"type": "mrkdwn", "text": "Reply with \`unblock $feature_id\` after resolving, or \`skip $feature_id\` to move on."}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "Feature blocked: $feature_id"
}

# Decision needed
notify_decision_needed() {
  local decision_id="$1"
  local question="$2"
  local options="$3"  # Comma-separated
  local context="${4:-}"
  local agent_id="${5:-}"

  # Build button elements
  local buttons=""
  IFS=',' read -ra OPTS <<< "$options"
  for opt in "${OPTS[@]}"; do
    opt=$(echo "$opt" | xargs)  # Trim whitespace
    buttons+="{\"type\": \"button\", \"text\": {\"type\": \"plain_text\", \"text\": \"$opt\"}, \"value\": \"${decision_id}:${opt}\", \"action_id\": \"decision_${opt}\"},"
  done
  buttons="${buttons%,}"  # Remove trailing comma

  local context_block=""
  if [[ -n "$context" ]]; then
    context_block=",{\"type\": \"context\", \"elements\": [{\"type\": \"mrkdwn\", \"text\": \"$context\"}]}"
  fi

  local blocks=$(cat <<EOF
[
  {
    "type": "header",
    "text": {"type": "plain_text", "text": "Decision Needed", "emoji": true}
  },
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": "*$question*"}
  },
  {
    "type": "actions",
    "block_id": "$decision_id",
    "elements": [$buttons]
  }
  $context_block
]
EOF
)
  send_slack_blocks "$blocks" "Decision needed: $question"
}

# Error occurred
notify_error() {
  local error_msg="$1"
  local feature_id="${2:-}"
  local agent_id="${3:-}"

  local context=""
  [[ -n "$feature_id" ]] && context+="Feature: $feature_id "
  [[ -n "$agent_id" ]] && context+="Agent: $agent_id"

  local blocks=$(cat <<EOF
[
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": ":x: *Error*\n$error_msg"}
  },
  {
    "type": "context",
    "elements": [
      {"type": "mrkdwn", "text": "$context"}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "Error: $error_msg"
}

# CI failure
notify_ci_failure() {
  local feature_id="$1"
  local branch="$2"
  local failure_type="$3"  # test, lint, type, build
  local attempt="${4:-1}"
  local max_attempts="${5:-3}"

  local blocks=$(cat <<EOF
[
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": ":warning: *CI Failed*\n*Feature:* $feature_id\n*Type:* $failure_type\n*Attempt:* $attempt/$max_attempts"}
  },
  {
    "type": "context",
    "elements": [
      {"type": "mrkdwn", "text": "Auto-fix in progress..."}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "CI failed for $feature_id (attempt $attempt)"
}

# Cost update
notify_cost_update() {
  local current_cost="$1"
  local daily_limit="${2:-50}"

  local percentage=$(echo "scale=0; ($current_cost / $daily_limit) * 100" | bc 2>/dev/null || echo "0")

  local emoji=":moneybag:"
  [[ $percentage -gt 75 ]] && emoji=":warning:"
  [[ $percentage -gt 90 ]] && emoji=":rotating_light:"

  send_slack_text "$emoji Cost update: \$${current_cost} / \$${daily_limit} (${percentage}%)"
}

# Progress summary
notify_progress_summary() {
  local completed="$1"
  local in_progress="$2"
  local pending="$3"
  local blocked="$4"
  local total="$5"
  local cost="${6:-0}"
  local runtime="${7:-0}"

  local percentage=$(echo "scale=0; ($completed / $total) * 100" | bc 2>/dev/null || echo "0")

  # Create progress bar
  local filled=$((percentage / 10))
  local empty=$((10 - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  local blocks=$(cat <<EOF
[
  {
    "type": "header",
    "text": {"type": "plain_text", "text": "Progress Update", "emoji": true}
  },
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": "*Progress:* $bar ${percentage}% ($completed/$total)"}
  },
  {
    "type": "section",
    "fields": [
      {"type": "mrkdwn", "text": ":white_check_mark: Completed: $completed"},
      {"type": "mrkdwn", "text": ":arrows_counterclockwise: In Progress: $in_progress"},
      {"type": "mrkdwn", "text": ":hourglass: Pending: $pending"},
      {"type": "mrkdwn", "text": ":no_entry: Blocked: $blocked"}
    ]
  },
  {
    "type": "context",
    "elements": [
      {"type": "mrkdwn", "text": "Cost: \$$cost | Runtime: ${runtime}"}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "Progress: $completed/$total features complete"
}

# Daily summary
notify_daily_summary() {
  local features_completed="$1"
  local prs_merged="$2"
  local prs_pending="$3"
  local decisions_made="$4"
  local total_cost="$5"

  local blocks=$(cat <<EOF
[
  {
    "type": "header",
    "text": {"type": "plain_text", "text": "Daily Summary", "emoji": true}
  },
  {
    "type": "section",
    "fields": [
      {"type": "mrkdwn", "text": "*Features Completed:* $features_completed"},
      {"type": "mrkdwn", "text": "*PRs Merged:* $prs_merged"},
      {"type": "mrkdwn", "text": "*PRs Pending Review:* $prs_pending"},
      {"type": "mrkdwn", "text": "*Decisions Made:* $decisions_made"}
    ]
  },
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": "*Total Cost:* \$$total_cost"}
  },
  {
    "type": "actions",
    "elements": [
      {"type": "button", "text": {"type": "plain_text", "text": "Review Pending PRs"}, "value": "review_prs", "action_id": "review_prs", "style": "primary"},
      {"type": "button", "text": {"type": "plain_text", "text": "View Full Report"}, "value": "full_report", "action_id": "full_report"}
    ]
  }
]
EOF
)
  send_slack_blocks "$blocks" "Daily summary: $features_completed features completed"
}

# Ralph completed all work
notify_complete() {
  local total_features="$1"
  local total_prs="$2"
  local total_cost="$3"
  local total_runtime="$4"

  local blocks=$(cat <<EOF
[
  {
    "type": "header",
    "text": {"type": "plain_text", "text": "Ralph Complete!", "emoji": true}
  },
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": ":tada: All features implemented!"}
  },
  {
    "type": "section",
    "fields": [
      {"type": "mrkdwn", "text": "*Features:* $total_features"},
      {"type": "mrkdwn", "text": "*PRs Created:* $total_prs"},
      {"type": "mrkdwn", "text": "*Total Cost:* \$$total_cost"},
      {"type": "mrkdwn", "text": "*Runtime:* $total_runtime"}
    ]
  },
  {
    "type": "section",
    "text": {"type": "mrkdwn", "text": "Ready for review phase. Reply \`review\` to start."}
  }
]
EOF
)
  send_slack_blocks "$blocks" "Ralph complete! $total_features features implemented"
}

# =============================================================================
# CLI
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-help}" in
    start)
      notify_start "${2:-3}" "${3:-flat}"
      ;;
    feature-started)
      notify_feature_started "$2" "$3" "$4"
      ;;
    feature-completed)
      notify_feature_completed "$2" "$3" "$4" "$5" "$6"
      ;;
    blocked)
      notify_blocked "$2" "$3" "${4:-}"
      ;;
    decision)
      notify_decision_needed "$2" "$3" "$4" "${5:-}" "${6:-}"
      ;;
    error)
      notify_error "$2" "${3:-}" "${4:-}"
      ;;
    ci-failure)
      notify_ci_failure "$2" "$3" "$4" "${5:-1}" "${6:-3}"
      ;;
    cost)
      notify_cost_update "$2" "${3:-50}"
      ;;
    progress)
      notify_progress_summary "$2" "$3" "$4" "$5" "$6" "${7:-0}" "${8:-0}"
      ;;
    daily)
      notify_daily_summary "$2" "$3" "$4" "$5" "$6"
      ;;
    complete)
      notify_complete "$2" "$3" "$4" "$5"
      ;;
    text)
      send_slack_text "$2"
      ;;
    help|*)
      echo "Usage: $0 <command> [args...]"
      echo ""
      echo "Commands:"
      echo "  start <agents> <mode>                              - Ralph started"
      echo "  feature-started <id> <name> <agent>                - Feature work began"
      echo "  feature-completed <id> <name> <pr_url> <files> <tests> - Feature done"
      echo "  blocked <id> <reason> [agent]                      - Feature blocked"
      echo "  decision <id> <question> <options> [context] [agent] - Decision needed"
      echo "  error <message> [feature_id] [agent]               - Error occurred"
      echo "  ci-failure <id> <branch> <type> [attempt] [max]    - CI failed"
      echo "  cost <amount> [limit]                              - Cost update"
      echo "  progress <done> <wip> <pending> <blocked> <total> [cost] [runtime]"
      echo "  daily <features> <merged> <pending> <decisions> <cost>"
      echo "  complete <features> <prs> <cost> <runtime>         - All done"
      echo "  text <message>                                     - Simple text"
      echo ""
      echo "Environment:"
      echo "  SLACK_WEBHOOK_URL  - Slack incoming webhook URL"
      echo "  SLACK_BOT_TOKEN    - Slack bot token (preferred)"
      echo "  SLACK_CHANNEL      - Channel to post to (default: #ralph-updates)"
      ;;
  esac
fi

# Export functions for sourcing
export -f send_slack_text send_slack_blocks notify_start notify_feature_started notify_feature_completed notify_blocked notify_decision_needed notify_error notify_ci_failure notify_cost_update notify_progress_summary notify_daily_summary notify_complete
