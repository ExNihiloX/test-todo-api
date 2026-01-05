#!/usr/bin/env bash
# ralph-integration.sh - Integration testing phase
# Merges all completed features and runs cross-feature tests

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"
source "$(dirname "$0")/ralph-merge-calculator.sh"

# =============================================================================
# INTEGRATION TESTING
# =============================================================================

# Create integration branch with all completed features merged
create_integration_branch() {
  local branch_name="integration/$(date +%Y%m%d-%H%M%S)"

  log "Creating integration branch: $branch_name"

  cd "$PROJECT_ROOT"

  # Ensure we're up to date
  git fetch origin "$DEFAULT_BRANCH"
  git checkout "$DEFAULT_BRANCH"
  git pull origin "$DEFAULT_BRANCH"

  # Create integration branch
  git checkout -b "$branch_name"

  # Get merge order
  local merge_order
  merge_order=$(calculate_merge_order)

  if [[ -z "$merge_order" ]]; then
    log "No features to integrate"
    echo "$branch_name"
    return 0
  fi

  # Merge each feature in order
  local merged=0
  local failed=0
  while IFS= read -r feature_id; do
    local feature_branch
    feature_branch=$(jq -r --arg id "$feature_id" '.features[] | select(.id == $id) | .branch' "$PRD_FILE")

    log "Merging $feature_id ($feature_branch)"

    if git merge --no-ff "origin/$feature_branch" -m "Merge $feature_id for integration testing"; then
      merged=$((merged + 1))
      log "Successfully merged: $feature_id"
    else
      failed=$((failed + 1))
      log_error "Merge conflict: $feature_id"
      git merge --abort || true

      # Record the conflict
      jq --arg id "$feature_id" '
        (.features[] | select(.id == $id)) |= . + {
          integration_status: "conflict"
        }
      ' "$PRD_FILE" > "${PRD_FILE}.tmp" && mv "${PRD_FILE}.tmp" "$PRD_FILE"
    fi
  done <<< "$merge_order"

  log "Integration branch created: $merged merged, $failed failed"

  if [[ $failed -gt 0 ]]; then
    notify_slack "⚠️ Integration branch has $failed merge conflicts"
  fi

  echo "$branch_name"
}

# Run integration tests using Claude
run_integration_tests() {
  local integration_branch="$1"

  log "Running integration tests on $integration_branch"

  # Ensure we're on the integration branch
  cd "$PROJECT_ROOT"
  git checkout "$integration_branch"

  # Get project test command
  local test_cmd="npm test"
  if [[ -f "$PROJECT_FILE" ]]; then
    test_cmd=$(jq -r '.test_command // "npm test"' "$PROJECT_FILE")
  fi

  # Check for integration test command
  local integration_test_cmd="npm run test:integration"
  if [[ -f "$PROJECT_FILE" ]]; then
    integration_test_cmd=$(jq -r '.integration_test_command // "npm run test:integration"' "$PROJECT_FILE")
  fi

  # Build the integration test prompt
  local prompt_file="${CACHE_DIR}/integration-prompt.md"

  cat > "$prompt_file" << PROMPT
# Integration Testing Task

You are on integration branch \`$integration_branch\` with all completed features merged.

## Your Tasks

1. **Run existing tests**
   \`\`\`bash
   $test_cmd
   \`\`\`
   All existing unit tests must pass.

2. **Write integration tests**
   Create tests in \`tests/integration/\` that verify features work together:
   - Test cross-feature data flows
   - Test API endpoint interactions
   - Test state consistency across features

3. **Run integration tests**
   \`\`\`bash
   $integration_test_cmd
   \`\`\`

4. **E2E smoke tests** (if applicable)
   - Start the application
   - Test critical user flows
   - Verify no console errors

## Feature Combinations to Test

$(jq -r '
  .integration_tests // [] |
  map("- \(.name): features \(.features | join(", "))") |
  join("\n")
' "$PRD_FILE")

## Completion

If all tests pass:
- Commit integration tests
- Output: \`<promise>INTEGRATION_COMPLETE</promise>\`

If tests fail:
- Document which feature combinations fail
- Output: \`<promise>INTEGRATION_FAILED:reason</promise>\`

## Important

- Do NOT fix feature code - only write tests
- If you find bugs, document them but don't fix
- Focus on verifying features work together
PROMPT

  # Run Claude for integration testing
  local output_file="${PROGRESS_DIR}/integration-test-output.log"

  log "Starting Claude integration test run"

  if claude --print "$prompt_file" 2>&1 | tee "$output_file"; then
    local output
    output=$(cat "$output_file")

    if echo "$output" | grep -q "<promise>INTEGRATION_COMPLETE</promise>"; then
      log "Integration tests passed!"
      notify_slack "✅ Integration tests passed on $integration_branch"
      return 0
    fi

    if echo "$output" | grep -qE "<promise>INTEGRATION_FAILED:"; then
      local reason
      reason=$(echo "$output" | grep -oE "<promise>INTEGRATION_FAILED:[^<]+" | sed 's/<promise>INTEGRATION_FAILED://')
      log_error "Integration tests failed: $reason"
      notify_slack "❌ Integration tests failed: $reason"
      return 1
    fi
  fi

  log_error "Integration test run did not complete properly"
  return 1
}

# Full integration pipeline
run_integration_pipeline() {
  log "=== Starting Integration Pipeline ==="

  # Check prerequisites
  if ! validate_merge_order; then
    log_error "Merge order validation failed - fix dependency cycles first"
    return 1
  fi

  # Check if there are completed features
  local completed_count
  completed_count=$(jq -r '[.features[] | select(.status == "completed")] | length' "$PRD_FILE")

  if [[ "$completed_count" -eq 0 ]]; then
    log "No completed features to integrate"
    return 0
  fi

  notify_slack "🔄 Starting integration testing ($completed_count features)"

  # Create integration branch
  local integration_branch
  integration_branch=$(create_integration_branch)

  if [[ -z "$integration_branch" ]]; then
    log_error "Failed to create integration branch"
    return 1
  fi

  # Run integration tests
  if run_integration_tests "$integration_branch"; then
    log "=== Integration Pipeline Complete ==="

    # Generate merge plan
    generate_merge_plan "${PROGRESS_DIR}/merge-plan.md"

    notify_slack "✅ Integration complete! Merge plan ready at progress/merge-plan.md"

    # Return to default branch
    git checkout "$DEFAULT_BRANCH"

    return 0
  else
    log_error "=== Integration Pipeline Failed ==="

    notify_slack "❌ Integration pipeline failed - check progress/integration-test-output.log"

    # Return to default branch
    git checkout "$DEFAULT_BRANCH"

    return 1
  fi
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-run}" in
    run)
      run_integration_pipeline
      ;;
    branch)
      create_integration_branch
      ;;
    test)
      run_integration_tests "${2:-$(git branch --show-current)}"
      ;;
    help|*)
      echo "Usage: $0 {run|branch|test}"
      echo ""
      echo "Commands:"
      echo "  run              - Full integration pipeline"
      echo "  branch           - Create integration branch only"
      echo "  test [branch]    - Run integration tests on branch"
      ;;
  esac
fi
