#!/usr/bin/env bash
# ralph-orchestrator.sh - Spawn and manage multiple parallel agents
# Main entry point for the autonomous developer system

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-claim.sh"

# =============================================================================
# ORCHESTRATOR CONFIGURATION
# =============================================================================

ORCHESTRATOR_PID=$$
AGENT_PIDS=()
HEARTBEAT_PID=""

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
  log "Orchestrator shutting down..."

  # Kill heartbeat daemon
  if [[ -n "${HEARTBEAT_PID:-}" ]] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi

  # Kill all agents (check array has elements first)
  if [[ ${#AGENT_PIDS[@]} -gt 0 ]]; then
    for pid in "${AGENT_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        log "Killing agent PID $pid"
        kill "$pid" 2>/dev/null || true
      fi
    done
  fi

  # Release any locks
  rm -rf "${LOCK_PREFIX:-/tmp/ralph-lock}-"* 2>/dev/null || true

  log "Orchestrator shutdown complete"
}

trap cleanup EXIT INT TERM

# =============================================================================
# ORCHESTRATOR FUNCTIONS
# =============================================================================

# Check all prerequisites before starting
check_prerequisites() {
  log "Checking prerequisites..."

  # Check for required commands
  for cmd in jq gh git claude; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: $cmd"
      return 1
    fi
  done

  # Check for PRD file
  if [[ ! -f "$PRD_FILE" ]]; then
    log_error "PRD file not found: $PRD_FILE"
    log "Run 'claude' with the prd-generator skill first to create the PRD"
    return 1
  fi

  # Validate PRD structure
  if ! jq -e '.features | length > 0' "$PRD_FILE" &>/dev/null; then
    log_error "PRD has no features defined"
    return 1
  fi

  # Check git status
  if [[ ! -d "$PROJECT_ROOT/.git" ]]; then
    log_error "Not a git repository: $PROJECT_ROOT"
    return 1
  fi

  # Check gh authentication
  if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI not authenticated. Run: gh auth login"
    return 1
  fi

  log "Prerequisites check passed"
  return 0
}

# Display current status
show_status() {
  if [[ ! -f "$PRD_FILE" ]]; then
    echo "No PRD file found"
    return
  fi

  echo "=== Autonomous Developer Status ==="
  echo ""

  # Project info
  local project_name
  project_name=$(jq -r '.project // "Unknown"' "$PRD_FILE")
  echo "Project: $project_name"
  echo ""

  # Feature counts
  local total pending in_progress completed blocked
  total=$(jq -r '.features | length' "$PRD_FILE")
  pending=$(jq -r '[.features[] | select(.status == "pending")] | length' "$PRD_FILE")
  in_progress=$(jq -r '[.features[] | select(.status == "in_progress")] | length' "$PRD_FILE")
  completed=$(jq -r '[.features[] | select(.status == "completed")] | length' "$PRD_FILE")
  blocked=$(jq -r '[.features[] | select(.status == "blocked")] | length' "$PRD_FILE")

  echo "Features: $completed/$total completed"
  echo "  - Pending: $pending"
  echo "  - In Progress: $in_progress"
  echo "  - Completed: $completed"
  echo "  - Blocked: $blocked"
  echo ""

  # Cost info
  local daily_cost
  daily_cost=$(get_daily_cost)
  echo "Today's Cost: \$$daily_cost / \$$MAX_DAILY_COST_USD"
  echo ""

  # In-progress details
  if [[ "$in_progress" -gt 0 ]]; then
    echo "In Progress:"
    jq -r '.features[] | select(.status == "in_progress") | "  - \(.id): \(.name) (agent: \(.claimed_by))"' "$PRD_FILE"
    echo ""
  fi

  # Blocked details
  if [[ "$blocked" -gt 0 ]]; then
    echo "⚠️  Blocked (needs human help):"
    jq -r '.features[] | select(.status == "blocked") | "  - \(.id): \(.blocked_reason)"' "$PRD_FILE"
    echo ""
  fi

  # Agent status
  echo "Agents: ${#AGENT_PIDS[@]} running"
  if [[ ${#AGENT_PIDS[@]} -gt 0 ]]; then
    for pid in "${AGENT_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        echo "  - PID $pid: running"
      else
        echo "  - PID $pid: stopped"
      fi
    done
  fi
}

# Start a single agent
start_agent() {
  local agent_id="$1"
  local agent_script="${RALPH_DIR}/ralph-agent.sh"

  log "Starting agent: $agent_id"

  # Run agent in background
  bash "$agent_script" run "$agent_id" &
  local pid=$!
  AGENT_PIDS+=("$pid")

  log "Agent $agent_id started with PID $pid"
  echo "$pid"
}

# Start the heartbeat daemon
start_heartbeat() {
  local heartbeat_script="${RALPH_DIR}/ralph-heartbeat.sh"

  log "Starting heartbeat daemon"

  bash "$heartbeat_script" daemon &
  HEARTBEAT_PID=$!

  log "Heartbeat daemon started with PID $HEARTBEAT_PID"
}

# Wait for all features to complete
wait_for_completion() {
  log "Waiting for all features to complete..."

  while true; do
    sleep 30

    # Check if we're done
    local pending in_progress
    pending=$(jq -r '[.features[] | select(.status == "pending")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    in_progress=$(jq -r '[.features[] | select(.status == "in_progress")] | length' "$PRD_FILE" 2>/dev/null || echo 0)

    if [[ "$pending" == "0" && "$in_progress" == "0" ]]; then
      log "All features complete!"
      return 0
    fi

    # Check if all agents have died
    local alive_agents=0
    if [[ ${#AGENT_PIDS[@]} -gt 0 ]]; then
      for pid in "${AGENT_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          alive_agents=$((alive_agents + 1))
        fi
      done
    fi

    if [[ $alive_agents -eq 0 && "$pending" -gt 0 ]]; then
      log_warn "All agents died but features remain - restarting agents"
      AGENT_PIDS=()
      for i in $(seq 1 "$NUM_AGENTS"); do
        start_agent "agent-$i"
      done
    fi

    # Log periodic status
    local completed
    completed=$(jq -r '[.features[] | select(.status == "completed")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
    local total
    total=$(jq -r '.features | length' "$PRD_FILE" 2>/dev/null || echo 0)
    log "Progress: $completed/$total features complete ($alive_agents agents active)"
  done
}

# Main orchestration function
run_orchestrator() {
  log "=== Autonomous Developer System v3 ==="
  log "Starting orchestrator with $NUM_AGENTS agents"

  # Initialize
  init_ralph

  # Check prerequisites
  if ! check_prerequisites; then
    log_error "Prerequisites check failed - aborting"
    return 1
  fi

  # Show initial status
  show_status

  # Notify start
  local project_name
  project_name=$(jq -r '.project // "Unknown"' "$PRD_FILE")
  local feature_count
  feature_count=$(jq -r '.features | length' "$PRD_FILE")
  notify_slack "🚀 Starting autonomous development: $project_name ($feature_count features, $NUM_AGENTS agents)"

  # Start heartbeat daemon
  start_heartbeat

  # Start agents
  for i in $(seq 1 "$NUM_AGENTS"); do
    start_agent "agent-$i"
    sleep 2  # Stagger agent starts
  done

  # Wait for completion
  wait_for_completion

  # Final status
  show_status

  # Check for blocked features
  local blocked
  blocked=$(jq -r '[.features[] | select(.status == "blocked")] | length' "$PRD_FILE")

  if [[ "$blocked" -gt 0 ]]; then
    log_warn "$blocked features are blocked and need human attention"
    notify_slack "⚠️ Development complete but $blocked features blocked - human help needed"
    return 1
  fi

  # Success!
  notify_slack "✅ All features implemented! Ready for integration testing and merge."
  log "=== Implementation Phase Complete ==="

  return 0
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-run}" in
    run)
      run_orchestrator
      ;;
    status)
      show_status
      ;;
    start-agent)
      start_agent "${2:-agent-manual}"
      ;;
    check)
      check_prerequisites
      ;;
    help|*)
      echo "Usage: $0 {run|status|start-agent|check}"
      echo ""
      echo "Commands:"
      echo "  run                  - Start the orchestrator with $NUM_AGENTS agents"
      echo "  status               - Show current development status"
      echo "  start-agent [name]   - Start a single agent manually"
      echo "  check                - Check prerequisites"
      echo ""
      echo "Environment Variables:"
      echo "  NUM_AGENTS           - Number of parallel agents (default: 3)"
      echo "  MAX_DAILY_COST_USD   - Daily cost limit (default: 50)"
      echo "  SLACK_WEBHOOK_URL    - Slack webhook for notifications"
      echo "  PROJECT_ROOT         - Project directory (default: current)"
      ;;
  esac
fi
