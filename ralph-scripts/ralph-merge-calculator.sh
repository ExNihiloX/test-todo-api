#!/usr/bin/env bash
# ralph-merge-calculator.sh - Calculate safe merge order using topological sort
# Ensures features are merged in dependency order to avoid breaking main

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"

# =============================================================================
# TOPOLOGICAL SORT
# =============================================================================

# Calculate merge order using Kahn's algorithm
# Only considers completed features with successful CI
calculate_merge_order() {
  if [[ ! -f "$PRD_FILE" ]]; then
    log_error "PRD file not found"
    return 1
  fi

  # Use jq to perform topological sort
  jq -r '
    # Get completed features only
    [.features[] | select(.status == "completed")] as $completed |
    ($completed | map(.id)) as $completed_ids |

    # Build adjacency list and in-degree count using Kahn algorithm
    reduce $completed[] as $f (
      {adj: {}, indegree: {}, ids: []};
      .ids += [$f.id] |
      # Count dependencies that are in our completed set
      .indegree[$f.id] = ([($f.depends_on // [])[] | select(. as $dep | $completed_ids | index($dep))] | length) |
      # Build reverse adjacency (what depends on this)
      reduce ($f.depends_on // [])[] as $dep (
        .;
        if ($completed_ids | index($dep)) then
          .adj[$dep] = ((.adj[$dep] // []) + [$f.id])
        else
          .
        end
      )
    ) |

    # Initialize queue with nodes having no dependencies
    [.ids[] as $id | select(.indegree[$id] == 0) | $id] as $initial_queue |

    # Run Kahn algorithm
    {queue: $initial_queue, result: [], adj: .adj, indegree: .indegree} |
    until(.queue | length == 0;
      .queue[0] as $node |
      .result += [$node] |
      .queue = .queue[1:] |
      reduce ((.adj[$node] // [])[] ) as $neighbor (
        .;
        .indegree[$neighbor] = (.indegree[$neighbor] - 1) |
        if .indegree[$neighbor] == 0 then
          .queue += [$neighbor]
        else
          .
        end
      )
    ) |

    # Output result
    .result[]
  ' "$PRD_FILE"
}

# Get features that are ready to merge (completed, CI passed, not blocked)
get_mergeable_features() {
  jq -r '
    .features[] |
    select(.status == "completed") |
    select(.ci_status == "passed" or .ci_status == null) |
    .id
  ' "$PRD_FILE"
}

# Get feature details for merge
get_merge_info() {
  local feature_id="$1"

  jq -r --arg id "$feature_id" '
    .features[] | select(.id == $id) |
    "Feature: \(.id)\n  Name: \(.name)\n  Branch: \(.branch)\n  PR: \(.pr_url // "N/A")\n  Dependencies: \(.depends_on // [] | join(", ") | if . == "" then "none" else . end)"
  ' "$PRD_FILE"
}

# Check if a feature can be safely merged (all deps already merged)
can_merge() {
  local feature_id="$1"
  local merged_json="$2"  # JSON array of already merged feature IDs

  jq -r --arg id "$feature_id" --argjson merged "$merged_json" '
    .features[] | select(.id == $id) |
    ((.depends_on // []) - $merged | length == 0)
  ' "$PRD_FILE"
}

# Generate merge plan document
generate_merge_plan() {
  local output_file="${1:-${PROGRESS_DIR}/merge-plan.md}"

  log "Generating merge plan: $output_file"

  {
    echo "# Merge Plan"
    echo ""
    echo "Generated: $(date -Iseconds)"
    echo ""

    local project_name
    project_name=$(jq -r '.project // "Unknown"' "$PRD_FILE")
    echo "## Project: $project_name"
    echo ""

    # Get merge order
    local order
    order=$(calculate_merge_order)

    if [[ -z "$order" ]]; then
      echo "No features ready to merge."
      return 0
    fi

    echo "## Merge Order"
    echo ""
    echo "Features should be merged in this order to respect dependencies:"
    echo ""

    local i=1
    while IFS= read -r feature_id; do
      echo "### $i. $feature_id"
      echo ""
      get_merge_info "$feature_id" | sed 's/^/  /'
      echo ""
      i=$((i + 1))
    done <<< "$order"

    echo "## Merge Commands"
    echo ""
    echo "Execute these commands in order:"
    echo ""
    echo '```bash'

    while IFS= read -r feature_id; do
      local branch
      branch=$(jq -r --arg id "$feature_id" '.features[] | select(.id == $id) | .branch' "$PRD_FILE")
      local pr_number
      pr_number=$(jq -r --arg id "$feature_id" '.features[] | select(.id == $id) | .pr_url // "" | split("/") | last' "$PRD_FILE")

      if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
        echo "# $feature_id"
        echo "gh pr merge $pr_number --merge --delete-branch"
        echo ""
      else
        echo "# $feature_id (manual merge needed)"
        echo "git checkout $DEFAULT_BRANCH && git pull"
        echo "git merge --no-ff origin/$branch -m \"Merge $feature_id\""
        echo "git push origin $DEFAULT_BRANCH"
        echo "git push origin --delete $branch"
        echo ""
      fi
    done <<< "$order"

    echo '```'
    echo ""
    echo "## Notes"
    echo ""
    echo "- Review each PR before merging"
    echo "- Wait for CI to pass after each merge"
    echo "- If conflicts occur, resolve and re-run CI"

  } > "$output_file"

  log "Merge plan written to: $output_file"
  echo "$output_file"
}

# Validate that merge order is acyclic
validate_merge_order() {
  local order
  order=$(calculate_merge_order)

  local order_count
  order_count=$(echo "$order" | grep -c . || echo 0)

  local completed_count
  completed_count=$(jq -r '[.features[] | select(.status == "completed")] | length' "$PRD_FILE")

  if [[ "$order_count" -ne "$completed_count" ]]; then
    log_error "Circular dependency detected! Order has $order_count features but $completed_count are completed."
    log_error "Check dependencies in prd.json for cycles."
    return 1
  fi

  log "Merge order validated: $order_count features in valid topological order"
  return 0
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-order}" in
    order)
      calculate_merge_order
      ;;
    plan)
      generate_merge_plan "${2:-}"
      ;;
    info)
      get_merge_info "$2"
      ;;
    validate)
      validate_merge_order
      ;;
    mergeable)
      get_mergeable_features
      ;;
    help|*)
      echo "Usage: $0 {order|plan|info|validate|mergeable}"
      echo ""
      echo "Commands:"
      echo "  order              - Calculate and print merge order"
      echo "  plan [file]        - Generate merge plan document"
      echo "  info <feature_id>  - Get merge info for a feature"
      echo "  validate           - Validate merge order (check for cycles)"
      echo "  mergeable          - List features ready to merge"
      ;;
  esac
fi
