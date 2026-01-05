#!/usr/bin/env bash
# ralph-agent.sh - Single agent worker for parallel feature implementation
# Runs a Ralph loop on a claimed feature until completion or failure

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-claim.sh"
source "$(dirname "$0")/ralph-heartbeat.sh"

# =============================================================================
# AGENT CONFIGURATION
# =============================================================================

AGENT_ID="${1:-agent-$$}"
AGENT_LOG="${PROGRESS_DIR}/${AGENT_ID}.log"

# =============================================================================
# AGENT FUNCTIONS
# =============================================================================

agent_log() {
  local msg="[$(date -Iseconds)] [$AGENT_ID] $1"
  echo "$msg" >> "$AGENT_LOG"
  log "$msg"
}

# Build the prompt for Claude based on feature and project context
build_prompt() {
  local feature_id="$1"

  # Get feature details
  local feature
  feature=$(get_feature "$feature_id")

  local name
  name=$(echo "$feature" | jq -r '.name')
  local workflow
  workflow=$(echo "$feature" | jq -r '.workflow_type // "direct"')
  local branch
  branch=$(echo "$feature" | jq -r '.branch')
  local depends_on
  depends_on=$(echo "$feature" | jq -r '.depends_on // [] | join(", ")')
  local api_endpoints
  api_endpoints=$(echo "$feature" | jq -r '.api_endpoints // [] | join(", ")')
  local packages
  packages=$(echo "$feature" | jq -r '.packages_needed // [] | join(" ")')
  local env_vars
  env_vars=$(echo "$feature" | jq -r '.env_vars_needed // [] | join(", ")')

  # Get project context
  local test_cmd="npm test"
  local lint_cmd="npm run lint"
  if [[ -f "$PROJECT_FILE" ]]; then
    test_cmd=$(jq -r '.test_command // "npm test"' "$PROJECT_FILE")
    lint_cmd=$(jq -r '.lint_command // "npm run lint"' "$PROJECT_FILE")
  fi

  # Get API contract if defined
  local api_contract=""
  if [[ -n "$api_endpoints" && -f "$PRD_FILE" ]]; then
    for endpoint in $(echo "$feature" | jq -r '.api_endpoints // [] | .[]'); do
      local contract
      contract=$(jq -r --arg ep "$endpoint" '.api_contracts[$ep] // empty' "$PRD_FILE" 2>/dev/null || true)
      if [[ -n "$contract" ]]; then
        api_contract="$api_contract
### $endpoint
\`\`\`json
$contract
\`\`\`"
      fi
    done
  fi

  cat << PROMPT
# Feature Implementation Task

## Feature: $name
- **ID**: $feature_id
- **Branch**: $branch
- **Workflow**: $workflow
${depends_on:+- **Dependencies**: $depends_on}
${api_endpoints:+- **API Endpoints**: $api_endpoints}
${packages:+- **Packages Needed**: $packages}
${env_vars:+- **Environment Variables Needed**: $env_vars}

${api_contract:+## API Contract
$api_contract}

## Instructions

You are implementing feature **$feature_id** on branch **$branch**.

### Workflow: $workflow

$(case "$workflow" in
  tdd)
    echo "1. Write failing tests first
2. Implement minimum code to pass tests
3. Refactor while keeping tests green
4. Ensure all tests pass: \`$test_cmd\`"
    ;;
  direct)
    echo "1. Implement the feature
2. Write tests for the implementation
3. Ensure all tests pass: \`$test_cmd\`"
    ;;
  docs)
    echo "1. Create/update documentation
2. Ensure examples are accurate
3. Verify links work"
    ;;
  *)
    echo "1. Implement the feature following project conventions
2. Write comprehensive tests
3. Ensure all tests pass"
    ;;
esac)

### Required Steps

1. **Setup**: Ensure you're on branch \`$branch\`, create if needed
2. **Install Dependencies**: ${packages:+\`npm install $packages\` or equivalent}
3. **Implement**: Follow the $workflow workflow
4. **Test**: Run \`$test_cmd\` - all tests must pass
5. **Lint**: Run \`$lint_cmd\` - fix any issues
6. **Commit**: Commit with message: "feat($feature_id): $name"
7. **Push**: Push to origin
8. **PR**: Create PR using \`gh pr create\`

### Completion

When the feature is fully implemented, tested, and a PR is created:
- Output: \`<promise>FEATURE_COMPLETE:$feature_id</promise>\`

If you encounter a blocker requiring human help:
- Output: \`<promise>BLOCKED:$feature_id:reason here</promise>\`

If tests fail after $MAX_ITERATIONS_PER_FEATURE attempts:
- Output: \`<promise>STUCK:$feature_id</promise>\`

### Project Context

Read \`CLAUDE.md\` if it exists for project conventions.
Read \`project.json\` for test/lint commands.
Check \`.claude/cache/\` for related feature specs.

PROMPT
}

# Run the Ralph loop for a feature
run_feature_loop() {
  local feature_id="$1"
  local iteration=0
  local feature
  feature=$(get_feature "$feature_id")
  local branch
  branch=$(echo "$feature" | jq -r '.branch')

  agent_log "Starting work on feature: $feature_id"

  # Create and checkout feature branch
  cd "$PROJECT_ROOT"
  git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
  git checkout -b "$branch" "origin/$DEFAULT_BRANCH" 2>/dev/null || git checkout "$branch" 2>/dev/null || true

  # Save prompt to file
  local prompt_file="${CACHE_DIR}/${feature_id}-prompt.md"
  build_prompt "$feature_id" > "$prompt_file"

  while [[ $iteration -lt $MAX_ITERATIONS_PER_FEATURE ]]; do
    iteration=$((iteration + 1))
    agent_log "Iteration $iteration/$MAX_ITERATIONS_PER_FEATURE for $feature_id"

    # Update heartbeat
    touch_heartbeat "$AGENT_ID"

    # Check budget
    if ! check_budget; then
      agent_log "Budget exceeded - pausing agent"
      notify_slack "🚨 Agent $AGENT_ID paused: budget exceeded"
      sleep 300
      continue
    fi

    # Run Claude with the prompt
    local output_file="${PROGRESS_DIR}/${AGENT_ID}-${feature_id}-iter${iteration}.log"

    # Use claude in non-interactive mode with permissions bypassed
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    if claude -p "$prompt_content" --dangerously-skip-permissions --output-format text 2>&1 | tee "$output_file"; then
      local output
      output=$(cat "$output_file")

      # Check for completion promise
      if echo "$output" | grep -q "<promise>FEATURE_COMPLETE:${feature_id}</promise>"; then
        agent_log "Feature $feature_id completed!"

        # Get PR URL if created
        local pr_url
        pr_url=$(gh pr view --json url -q '.url' 2>/dev/null || echo "")

        complete_feature "$feature_id" "$pr_url"
        return 0
      fi

      # Check for blocked promise
      if echo "$output" | grep -qE "<promise>BLOCKED:${feature_id}:"; then
        local reason
        reason=$(echo "$output" | grep -oE "<promise>BLOCKED:${feature_id}:[^<]+" | sed "s/<promise>BLOCKED:${feature_id}://")
        agent_log "Feature $feature_id blocked: $reason"
        block_feature "$feature_id" "$reason"
        return 1
      fi

      # Check for stuck promise
      if echo "$output" | grep -q "<promise>STUCK:${feature_id}</promise>"; then
        agent_log "Feature $feature_id stuck after $iteration iterations"
        block_feature "$feature_id" "Stuck after $iteration iterations"
        return 1
      fi
    else
      agent_log "Claude execution failed on iteration $iteration"
    fi

    # Brief pause between iterations
    sleep 5
  done

  # Max iterations reached
  agent_log "Feature $feature_id reached max iterations ($MAX_ITERATIONS_PER_FEATURE)"
  block_feature "$feature_id" "Max iterations reached"
  return 1
}

# Main agent loop - continuously claim and work on features
run_agent() {
  agent_log "Agent started"
  init_ralph

  while true; do
    # Update heartbeat
    touch_heartbeat "$AGENT_ID"

    # Check budget
    if ! check_budget; then
      agent_log "Budget exceeded - agent sleeping"
      sleep 300
      continue
    fi

    # Try to claim next feature
    local feature_id
    feature_id=$(claim_next_feature "$AGENT_ID" 2>/dev/null || echo "")

    if [[ -z "$feature_id" ]]; then
      # No features available - check if we're done
      local pending
      pending=$(jq -r '[.features[] | select(.status == "pending")] | length' "$PRD_FILE" 2>/dev/null || echo 0)
      local in_progress
      in_progress=$(jq -r '[.features[] | select(.status == "in_progress")] | length' "$PRD_FILE" 2>/dev/null || echo 0)

      if [[ "$pending" == "0" && "$in_progress" == "0" ]]; then
        agent_log "All features complete - agent exiting"
        notify_slack "🎉 Agent $AGENT_ID: All features complete!"
        return 0
      fi

      agent_log "No claimable features, waiting... (pending: $pending, in_progress: $in_progress)"
      sleep 30
      continue
    fi

    # Work on the claimed feature
    if run_feature_loop "$feature_id"; then
      agent_log "Successfully completed $feature_id"
    else
      agent_log "Failed to complete $feature_id"
    fi

    # Brief pause before claiming next
    sleep 5
  done
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-run}" in
    run)
      AGENT_ID="${2:-agent-$$}"
      run_agent
      ;;
    feature)
      AGENT_ID="${2:-agent-$$}"
      run_feature_loop "$3"
      ;;
    prompt)
      build_prompt "$2"
      ;;
    help|*)
      echo "Usage: $0 {run|feature|prompt} [agent_id] [feature_id]"
      echo ""
      echo "Commands:"
      echo "  run [agent_id]                  - Run continuous agent loop"
      echo "  feature <agent_id> <feature_id> - Work on specific feature"
      echo "  prompt <feature_id>             - Generate prompt for feature"
      ;;
  esac
fi
