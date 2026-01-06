#!/usr/bin/env bash
# ralph-config.sh - Configuration for Autonomous Developer System v3
# Source this file in other ralph scripts: source "$(dirname "$0")/ralph-config.sh"

set -euo pipefail

# =============================================================================
# PATHS
# =============================================================================
RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
PRD_FILE="${PROJECT_ROOT}/prd.json"
PROJECT_FILE="${PROJECT_ROOT}/project.json"
PROGRESS_DIR="${PROJECT_ROOT}/progress"
CACHE_DIR="${PROJECT_ROOT}/.claude/cache"
COST_LOG="${PROGRESS_DIR}/cost.log"
STATE_FILE="${PROGRESS_DIR}/state.json"
LOCK_PREFIX="/tmp/ralph-lock"

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================
NUM_AGENTS=3
MAX_ITERATIONS_PER_FEATURE=20
MAX_CI_ATTEMPTS=3
STALE_CLAIM_THRESHOLD=600  # 10 minutes in seconds
HEARTBEAT_INTERVAL=60       # Check every minute

# =============================================================================
# COST LIMITS (Claude API pricing as of 2025)
# =============================================================================
MAX_DAILY_COST_USD=50
COST_PER_INPUT_TOKEN=0.000003    # $3 per 1M tokens
COST_PER_OUTPUT_TOKEN=0.000015   # $15 per 1M tokens

# =============================================================================
# SLACK CONFIGURATION
# =============================================================================
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#dev-updates}"

# =============================================================================
# LINEAR CONFIGURATION
# =============================================================================
LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-}"

# =============================================================================
# GIT CONFIGURATION
# =============================================================================
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
FEATURE_BRANCH_PREFIX="feature"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log() {
  local level="${2:-INFO}"
  echo "[$(date -Iseconds)] [$level] $1" >&2
}

log_error() {
  log "$1" "ERROR"
}

log_warn() {
  log "$1" "WARN"
}

log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    log "$1" "DEBUG"
  fi
}

notify_slack() {
  local message="$1"
  if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -H 'Content-type: application/json' \
      -d "{\"text\":\"$message\"}" >/dev/null 2>&1 || true
    log "Slack notification sent: $message"
  else
    log_debug "Slack not configured, skipping: $message"
  fi
}

# Initialize directories and state file
# IMPORTANT: This should only be called ONCE at orchestrator startup
# Never call from agents - they should only read/update existing state
init_ralph() {
  mkdir -p "$PROGRESS_DIR" "$CACHE_DIR"
  touch "$COST_LOG"

  if [[ ! -f "$PRD_FILE" ]]; then
    log_warn "No prd.json found - run project-analyzer skill first"
    return 1
  fi

  # Initialize state.json from prd.json ONLY if it doesn't exist
  # NEVER overwrite existing state - that would lose progress!
  if [[ ! -f "$STATE_FILE" ]]; then
    log "Initializing state.json from prd.json"
    jq '{
      features: [.features[] | {
        id: .id,
        status: "pending",
        claimed_by: null,
        claimed_at: null,
        completed_at: null,
        pr_url: null,
        branch: null,
        ci_status: null,
        ci_attempts: 0
      }]
    }' "$PRD_FILE" > "$STATE_FILE"
  else
    log_debug "State file exists, preserving existing progress"
  fi
}

# Ensure state file exists (safe to call multiple times)
# Unlike init_ralph, this never overwrites
ensure_state_file() {
  if [[ ! -f "$STATE_FILE" ]]; then
    log_error "State file missing! Run orchestrator first to initialize."
    return 1
  fi
  return 0
}

# Get today's total cost
get_daily_cost() {
  local today
  today=$(date +%Y-%m-%d)
  awk -F',' -v today="$today" '
    $1 ~ today { sum += $6 }
    END { printf "%.4f", sum+0 }
  ' "$COST_LOG"
}

# Log cost for a Claude call
log_cost() {
  local agent_id="$1"
  local feature_id="$2"
  local tokens_in="$3"
  local tokens_out="$4"

  local cost
  cost=$(echo "scale=6; ($tokens_in * $COST_PER_INPUT_TOKEN) + ($tokens_out * $COST_PER_OUTPUT_TOKEN)" | bc)

  echo "$(date -Iseconds),$agent_id,$feature_id,$tokens_in,$tokens_out,$cost" >> "$COST_LOG"

  local daily_total
  daily_total=$(get_daily_cost)

  if (( $(echo "$daily_total > $MAX_DAILY_COST_USD" | bc -l) )); then
    notify_slack "🚨 COST LIMIT REACHED: \$$daily_total spent today (limit: \$$MAX_DAILY_COST_USD)"
    return 1
  fi

  log_debug "Cost logged: \$$cost (daily total: \$$daily_total)"
  return 0
}

# Check if we're under budget
check_budget() {
  local daily_total
  daily_total=$(get_daily_cost)

  if (( $(echo "$daily_total > $MAX_DAILY_COST_USD" | bc -l) )); then
    log_error "Daily cost limit exceeded: \$$daily_total > \$$MAX_DAILY_COST_USD"
    return 1
  fi
  return 0
}

# Export all functions for subshells
export -f log log_error log_warn log_debug notify_slack init_ralph ensure_state_file get_daily_cost log_cost check_budget

# Export all variables
export RALPH_DIR PROJECT_ROOT PRD_FILE PROJECT_FILE PROGRESS_DIR CACHE_DIR COST_LOG STATE_FILE LOCK_PREFIX
export NUM_AGENTS MAX_ITERATIONS_PER_FEATURE MAX_CI_ATTEMPTS STALE_CLAIM_THRESHOLD HEARTBEAT_INTERVAL
export MAX_DAILY_COST_USD COST_PER_INPUT_TOKEN COST_PER_OUTPUT_TOKEN
export SLACK_WEBHOOK_URL SLACK_CHANNEL LINEAR_TEAM_ID DEFAULT_BRANCH FEATURE_BRANCH_PREFIX
