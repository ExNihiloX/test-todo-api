#!/usr/bin/env bash
# ralph-status.sh - Status reporting utilities for Ralph
# Provides summary information about current run state

set -euo pipefail

# Only source config if not already sourced
if [[ -z "${RALPH_DIR:-}" ]]; then
  source "$(dirname "$0")/ralph-config.sh"
fi

# =============================================================================
# STATUS FUNCTIONS
# =============================================================================

# Get feature counts by status
get_feature_counts() {
  local completed=0 in_progress=0 pending=0 blocked=0 total=0

  if [[ -f "$STATE_FILE" ]]; then
    completed=$(jq '[.features[] | select(.status == "completed")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    in_progress=$(jq '[.features[] | select(.status == "in_progress")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    pending=$(jq '[.features[] | select(.status == "pending")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    blocked=$(jq '[.features[] | select(.status == "blocked")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    total=$(jq '.features | length' "$STATE_FILE" 2>/dev/null || echo 0)
  elif [[ -f "$PRD_FILE" ]]; then
    completed=$(jq '[.features[] | select(.status == "completed")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    in_progress=$(jq '[.features[] | select(.status == "in_progress")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    pending=$(jq '[.features[] | select(.status == "pending")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    blocked=$(jq '[.features[] | select(.status == "blocked")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    total=$(jq '.features | length' "$PRD_FILE" 2>/dev/null || echo 0)
  fi

  echo "$completed $in_progress $pending $blocked $total"
}

# Get current cost from logs
get_current_cost() {
  local cost="0.00"
  if [[ -f "${PROGRESS_DIR}/cost.log" ]]; then
    cost=$(awk -F',' '{sum += $6} END {printf "%.2f", sum}' "${PROGRESS_DIR}/cost.log" 2>/dev/null || echo "0.00")
  fi
  echo "$cost"
}

# Get runtime since start
get_runtime() {
  local runtime="unknown"
  if [[ -f "${PROGRESS_DIR}/start_time" ]]; then
    local start_ts=$(cat "${PROGRESS_DIR}/start_time")
    local now_ts=$(date +%s)
    local elapsed=$((now_ts - start_ts))
    local hours=$((elapsed / 3600))
    local mins=$(( (elapsed % 3600) / 60 ))
    runtime="${hours}h ${mins}m"
  fi
  echo "$runtime"
}

# Get active agents
get_active_agents() {
  local count=0
  for hb in "$PROGRESS_DIR"/*.heartbeat; do
    [[ -f "$hb" ]] || continue
    local age=$(( $(date +%s) - $(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0) ))
    # Consider active if heartbeat within last 2 minutes
    [[ $age -lt 120 ]] && count=$((count + 1))
  done
  echo "$count"
}

# Check system status (running/paused/stopped)
get_system_status() {
  if [[ -f "$PROGRESS_DIR/.abort" ]]; then
    echo "stopped"
  elif [[ -f "$PROGRESS_DIR/.paused" ]]; then
    echo "paused"
  elif [[ -f "$PROGRESS_DIR/orchestrator.pid" ]]; then
    local pid=$(cat "$PROGRESS_DIR/orchestrator.pid")
    if kill -0 "$pid" 2>/dev/null; then
      echo "running"
    else
      echo "stopped"
    fi
  else
    echo "idle"
  fi
}

# Build progress bar
build_progress_bar() {
  local completed=$1
  local total=$2
  local width=10

  if [[ $total -eq 0 ]]; then
    echo "░░░░░░░░░░"
    return
  fi

  local filled=$(( (completed * width) / total ))
  local empty=$((width - filled))

  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  echo "$bar"
}

# Get text status summary (for Slack/CLI)
get_status_summary() {
  read -r completed in_progress pending blocked total <<< "$(get_feature_counts)"
  local cost=$(get_current_cost)
  local runtime=$(get_runtime)
  local agents=$(get_active_agents)
  local status=$(get_system_status)
  local bar=$(build_progress_bar "$completed" "$total")

  # Status emoji
  local status_emoji="🟢"
  case "$status" in
    paused) status_emoji="🟡 PAUSED" ;;
    stopped) status_emoji="🔴 STOPPED" ;;
    idle) status_emoji="⚪ IDLE" ;;
  esac

  # Calculate percentage
  local pct=0
  [[ $total -gt 0 ]] && pct=$(( (completed * 100) / total ))

  cat << EOF
$status_emoji Ralph Status

Progress: $bar $pct% ($completed/$total)
✅ Completed: $completed
🔄 In Progress: $in_progress
⏳ Pending: $pending
🚫 Blocked: $blocked

👥 Active Agents: $agents
💰 Cost: \$$cost
⏱️ Runtime: $runtime
EOF
}

# Get JSON status (for programmatic use)
get_status_json() {
  read -r completed in_progress pending blocked total <<< "$(get_feature_counts)"
  local cost=$(get_current_cost)
  local runtime=$(get_runtime)
  local agents=$(get_active_agents)
  local status=$(get_system_status)

  cat << EOF
{
  "status": "$status",
  "features": {
    "completed": $completed,
    "in_progress": $in_progress,
    "pending": $pending,
    "blocked": $blocked,
    "total": $total
  },
  "agents": $agents,
  "cost": "$cost",
  "runtime": "$runtime"
}
EOF
}

# List features by status
list_features() {
  local filter="${1:-all}"
  local source_file="$STATE_FILE"
  [[ ! -f "$source_file" ]] && source_file="$PRD_FILE"
  [[ ! -f "$source_file" ]] && echo "No PRD found" && return 1

  echo "=== Features ($filter) ==="

  if [[ "$filter" == "all" ]]; then
    jq -r '.features[] | "[\(.status | ascii_upcase)] \(.id): \(.name)"' "$source_file"
  else
    jq -r --arg status "$filter" '.features[] | select(.status == $status) | "[\(.status | ascii_upcase)] \(.id): \(.name)"' "$source_file"
  fi
}

# Get details for a specific feature
get_feature_status() {
  local feature_id="$1"
  local source_file="$STATE_FILE"
  [[ ! -f "$source_file" ]] && source_file="$PRD_FILE"
  [[ ! -f "$source_file" ]] && echo "No PRD found" && return 1

  jq --arg id "$feature_id" '.features[] | select(.id == $id)' "$source_file"
}

# =============================================================================
# CLI
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-summary}" in
    summary|status)
      get_status_summary
      ;;
    json)
      get_status_json
      ;;
    counts)
      read -r completed in_progress pending blocked total <<< "$(get_feature_counts)"
      echo "Completed: $completed"
      echo "In Progress: $in_progress"
      echo "Pending: $pending"
      echo "Blocked: $blocked"
      echo "Total: $total"
      ;;
    features)
      list_features "${2:-all}"
      ;;
    feature)
      get_feature_status "$2"
      ;;
    cost)
      echo "Current cost: \$$(get_current_cost)"
      ;;
    runtime)
      echo "Runtime: $(get_runtime)"
      ;;
    agents)
      echo "Active agents: $(get_active_agents)"
      ;;
    system)
      echo "System status: $(get_system_status)"
      ;;
    help|*)
      echo "Usage: $0 <command>"
      echo ""
      echo "Commands:"
      echo "  summary    - Full status summary (default)"
      echo "  json       - Status as JSON"
      echo "  counts     - Feature counts only"
      echo "  features [filter] - List features (all|pending|in_progress|completed|blocked)"
      echo "  feature <id>      - Get specific feature details"
      echo "  cost       - Current cost"
      echo "  runtime    - Current runtime"
      echo "  agents     - Active agent count"
      echo "  system     - System status (running/paused/stopped/idle)"
      ;;
  esac
fi

# Export functions for sourcing
export -f get_status_summary get_status_json get_feature_counts get_current_cost get_runtime get_active_agents get_system_status list_features get_feature_status
