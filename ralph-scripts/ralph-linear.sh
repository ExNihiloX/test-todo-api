#!/usr/bin/env bash
# ralph-linear.sh - Linear API integration for Ralph
# Provides GraphQL API wrapper for issue management

set -euo pipefail

# Linear API endpoint
LINEAR_API="https://api.linear.app/graphql"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Check for required env vars
check_config() {
  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    echo "ERROR: LINEAR_API_KEY not set" >&2
    echo "Get your API key from: https://linear.app/settings/api" >&2
    return 1
  fi
}

# =============================================================================
# GRAPHQL HELPERS
# =============================================================================

# Execute GraphQL query/mutation
graphql() {
  local query="$1"
  local variables="${2:-}"

  # Build payload - handle empty variables
  local payload
  if [[ -z "$variables" || "$variables" == "{}" ]]; then
    payload=$(jq -n --arg q "$query" '{query: $q, variables: {}}')
  else
    # Write variables to temp file to avoid shell escaping issues
    local tmp_vars
    tmp_vars=$(mktemp)
    echo "$variables" > "$tmp_vars"
    payload=$(jq -n --arg q "$query" --slurpfile v "$tmp_vars" '{query: $q, variables: $v[0]}')
    rm -f "$tmp_vars"
  fi

  curl -s -X POST "$LINEAR_API" \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

# Check for errors in response
check_response() {
  local response="$1"
  local errors
  errors=$(echo "$response" | jq -r '.errors // empty')

  if [[ -n "$errors" && "$errors" != "null" ]]; then
    echo "ERROR: Linear API error:" >&2
    echo "$errors" | jq -r '.[].message' >&2
    return 1
  fi
  return 0
}

# =============================================================================
# TEAM OPERATIONS
# =============================================================================

# List all teams
list_teams() {
  local response
  response=$(graphql '
    query {
      teams {
        nodes {
          id
          name
          key
        }
      }
    }
  ')

  check_response "$response" || return 1
  echo "$response" | jq -r '.data.teams.nodes[] | "\(.id)\t\(.key)\t\(.name)"'
}

# Get workflow states for a team
get_states() {
  local team_id="${1:-$LINEAR_TEAM_ID}"

  if [[ -z "$team_id" ]]; then
    echo "ERROR: Team ID required (set LINEAR_TEAM_ID or pass as argument)" >&2
    return 1
  fi

  local variables
  variables=$(jq -n --arg teamId "$team_id" '{teamId: $teamId}')

  local response
  response=$(graphql '
    query($teamId: String!) {
      team(id: $teamId) {
        states {
          nodes {
            id
            name
            type
            position
          }
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1
  echo "$response" | jq -r '.data.team.states.nodes | sort_by(.position) | .[] | "\(.id)\t\(.type)\t\(.name)"'
}

# Get state ID by name
get_state_id() {
  local state_name="$1"
  local team_id="${2:-$LINEAR_TEAM_ID}"

  local variables
  variables=$(jq -n --arg teamId "$team_id" '{teamId: $teamId}')

  local response
  response=$(graphql '
    query($teamId: String!) {
      team(id: $teamId) {
        states {
          nodes {
            id
            name
          }
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1
  echo "$response" | jq -r --arg name "$state_name" '.data.team.states.nodes[] | select(.name == $name) | .id'
}

# =============================================================================
# ISSUE OPERATIONS
# =============================================================================

# Create a new issue
create_issue() {
  local title="$1"
  local description="${2:-}"
  local team_id="${3:-$LINEAR_TEAM_ID}"
  local project_id="${LINEAR_PROJECT_ID:-}"

  if [[ -z "$team_id" ]]; then
    echo "ERROR: Team ID required" >&2
    return 1
  fi

  # Build input JSON using jq (avoids shell escaping issues)
  local input
  input=$(jq -n \
    --arg teamId "$team_id" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg projectId "$project_id" \
    '{
      teamId: $teamId,
      title: $title
    } + (if $desc != "" then {description: $desc} else {} end)
      + (if $projectId != "" then {projectId: $projectId} else {} end)'
  )

  # Build variables JSON
  local variables
  variables=$(jq -n --argjson input "$input" '{input: $input}')

  local response
  response=$(graphql '
    mutation($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue {
          id
          identifier
          url
          title
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1

  local success
  success=$(echo "$response" | jq -r '.data.issueCreate.success')

  if [[ "$success" == "true" ]]; then
    echo "$response" | jq -r '.data.issueCreate.issue | "\(.id)\t\(.identifier)\t\(.url)"'
  else
    echo "ERROR: Failed to create issue" >&2
    return 1
  fi
}

# Get issue details
get_issue() {
  local issue_id="$1"

  local variables
  variables=$(jq -n --arg id "$issue_id" '{id: $id}')

  local response
  response=$(graphql '
    query($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        description
        url
        state {
          id
          name
          type
        }
        assignee {
          id
          name
        }
        comments {
          nodes {
            id
            body
            createdAt
            user {
              name
            }
          }
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1
  echo "$response" | jq '.data.issue'
}

# Update issue status
update_status() {
  local issue_id="$1"
  local state_name="$2"

  # Get state ID from name
  local state_id
  state_id=$(get_state_id "$state_name")

  if [[ -z "$state_id" ]]; then
    echo "ERROR: State '$state_name' not found" >&2
    return 1
  fi

  local variables
  variables=$(jq -n --arg id "$issue_id" --arg stateId "$state_id" '{id: $id, stateId: $stateId}')

  local response
  response=$(graphql '
    mutation($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
        issue {
          id
          state {
            name
          }
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1

  local success
  success=$(echo "$response" | jq -r '.data.issueUpdate.success')

  if [[ "$success" == "true" ]]; then
    echo "Updated to: $(echo "$response" | jq -r '.data.issueUpdate.issue.state.name')"
  else
    echo "ERROR: Failed to update status" >&2
    return 1
  fi
}

# =============================================================================
# COMMENT OPERATIONS
# =============================================================================

# Add comment to issue
add_comment() {
  local issue_id="$1"
  local body="$2"

  local variables
  variables=$(jq -n --arg issueId "$issue_id" --arg body "$body" '{issueId: $issueId, body: $body}')

  local response
  response=$(graphql '
    mutation($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) {
        success
        comment {
          id
          createdAt
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1

  local success
  success=$(echo "$response" | jq -r '.data.commentCreate.success')

  if [[ "$success" == "true" ]]; then
    echo "Comment added: $(echo "$response" | jq -r '.data.commentCreate.comment.id')"
  else
    echo "ERROR: Failed to add comment" >&2
    return 1
  fi
}

# Get comments for issue
get_comments() {
  local issue_id="$1"
  local since="${2:-}"

  local variables
  variables=$(jq -n --arg id "$issue_id" '{id: $id}')

  local response
  response=$(graphql '
    query($id: String!) {
      issue(id: $id) {
        comments {
          nodes {
            id
            body
            createdAt
            user {
              id
              name
              email
            }
          }
        }
      }
    }
  ' "$variables")

  check_response "$response" || return 1

  if [[ -n "$since" ]]; then
    # Filter comments after timestamp
    echo "$response" | jq -r --arg since "$since" '
      .data.issue.comments.nodes
      | map(select(.createdAt > $since))
      | sort_by(.createdAt)
    '
  else
    echo "$response" | jq -r '.data.issue.comments.nodes | sort_by(.createdAt)'
  fi
}

# Poll for new comments (for decision flow)
poll_comments() {
  local issue_id="$1"
  local since="$2"
  local timeout="${3:-300}"  # 5 minute default timeout
  local interval="${4:-30}"   # 30 second poll interval

  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    local comments
    comments=$(get_comments "$issue_id" "$since")

    local count
    count=$(echo "$comments" | jq 'length')

    if [[ "$count" -gt 0 ]]; then
      # Found new comments - return the first human one
      # (filter out bot comments if needed)
      echo "$comments" | jq -r '.[0]'
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "TIMEOUT" >&2
  return 1
}

# =============================================================================
# DECISION FLOW
# =============================================================================

# Post a decision request and wait for response
request_decision() {
  local issue_id="$1"
  local context="$2"
  local options="$3"  # JSON array of options

  # Build decision comment
  local comment="**Decision Needed**

$context

**Options:**
"

  local i=1
  while read -r option; do
    comment="$comment
$i. $option"
    i=$((i + 1))
  done < <(echo "$options" | jq -r '.[]')

  comment="$comment

Please reply with your choice (number) or provide alternative guidance."

  # Update status to Blocked
  update_status "$issue_id" "${LINEAR_STATE_BLOCKED:-Blocked}" >/dev/null

  # Add decision comment
  add_comment "$issue_id" "$comment" >/dev/null

  # Record timestamp
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  echo "$timestamp"
}

# Wait for and parse decision response (uses poll loop for long waits)
await_decision() {
  local issue_id="$1"
  local since="$2"
  local max_hours="${3:-6}"  # Default 6 hours max wait

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  echo "Waiting for decision on Linear issue (up to ${max_hours}h)..." >&2

  # Calculate iterations: each poll is ~2 min, so iterations = hours * 30
  local max_iterations=$((max_hours * 30))

  local response
  response=$("$script_dir/ralph-poll-loop.sh" "$issue_id" "$since" "$max_iterations" 120 30 2>&1)

  # Check if we got a response
  if [[ "$response" == *"RESPONSE_RECEIVED"* ]]; then
    # Extract JSON from response
    local json
    json=$(echo "$response" | sed -n '/RESPONSE_RECEIVED/,$ p' | tail -n +2)

    # Extract the response body
    local body
    body=$(echo "$json" | jq -r '.body')

    # Try to parse as number (option selection)
    local choice
    choice=$(echo "$body" | grep -oE '^[0-9]+' | head -1)

    if [[ -n "$choice" ]]; then
      echo "$choice"
    else
      # Return full text for custom response
      echo "$body"
    fi

    # Update status back to In Progress
    update_status "$issue_id" "${LINEAR_STATE_IN_PROGRESS:-In Progress}" >/dev/null
  else
    echo "TIMEOUT"
    return 1
  fi
}

# =============================================================================
# UTILITY
# =============================================================================

# Test connection
test_connection() {
  check_config || return 1

  local response
  response=$(graphql '
    query {
      viewer {
        id
        name
        email
      }
    }
  ')

  if check_response "$response"; then
    local name
    name=$(echo "$response" | jq -r '.data.viewer.name')
    echo "Connected as: $name"
    return 0
  else
    echo "Connection failed" >&2
    return 1
  fi
}

# =============================================================================
# CLI
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_config || exit 1

  case "${1:-help}" in
    test)
      test_connection
      ;;
    teams)
      echo "ID                                  	KEY	NAME"
      list_teams
      ;;
    states)
      echo "ID                                  	TYPE        	NAME"
      get_states "${2:-}"
      ;;
    create)
      if [[ -z "${2:-}" ]]; then
        echo "Usage: $0 create <title> [description]" >&2
        exit 1
      fi
      create_issue "$2" "${3:-}"
      ;;
    get)
      if [[ -z "${2:-}" ]]; then
        echo "Usage: $0 get <issue-id>" >&2
        exit 1
      fi
      get_issue "$2"
      ;;
    status)
      if [[ -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Usage: $0 status <issue-id> <state-name>" >&2
        exit 1
      fi
      update_status "$2" "$3"
      ;;
    comment)
      if [[ -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Usage: $0 comment <issue-id> <body>" >&2
        exit 1
      fi
      add_comment "$2" "$3"
      ;;
    comments)
      if [[ -z "${2:-}" ]]; then
        echo "Usage: $0 comments <issue-id> [since-timestamp]" >&2
        exit 1
      fi
      get_comments "$2" "${3:-}"
      ;;
    poll)
      if [[ -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Usage: $0 poll <issue-id> <since-timestamp> [timeout] [interval]" >&2
        exit 1
      fi
      poll_comments "$2" "$3" "${4:-300}" "${5:-30}"
      ;;
    poll-loop)
      if [[ -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Usage: $0 poll-loop <issue-id> <since-timestamp> [max-hours]" >&2
        exit 1
      fi
      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      max_hours="${4:-6}"
      max_iterations=$((max_hours * 30))
      "$SCRIPT_DIR/ralph-poll-loop.sh" "$2" "$3" "$max_iterations" 120 30
      ;;
    decision)
      if [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]]; then
        echo "Usage: $0 decision <issue-id> <context> <options-json> [max-hours]" >&2
        echo "Example: $0 decision abc-123 'Which approach?' '[\"Option A\",\"Option B\"]' 2" >&2
        exit 1
      fi
      timestamp=$(request_decision "$2" "$3" "$4")
      await_decision "$2" "$timestamp" "${5:-6}"
      ;;
    help|*)
      echo "Usage: $0 <command> [args]"
      echo ""
      echo "Commands:"
      echo "  test                    - Test API connection"
      echo "  teams                   - List all teams"
      echo "  states [team-id]        - List workflow states"
      echo "  create <title> [desc]   - Create new issue"
      echo "  get <issue-id>          - Get issue details"
      echo "  status <id> <state>     - Update issue status"
      echo "  comment <id> <body>     - Add comment to issue"
      echo "  comments <id> [since]   - Get issue comments"
      echo "  poll <id> <since>       - Poll for new comments (short)"
      echo "  poll-loop <id> <since>  - Poll loop for hours (autonomous)"
      echo "  decision <id> <ctx> <opts> - Full decision flow (block+poll+unblock)"
      echo ""
      echo "Environment:"
      echo "  LINEAR_API_KEY          - Required: API key from Linear"
      echo "  LINEAR_TEAM_ID          - Default team for operations"
      echo "  LINEAR_PROJECT_ID       - Optional: Project to add issues to"
      ;;
  esac
fi

# Export functions for sourcing
export -f graphql check_response list_teams get_states get_state_id \
  create_issue get_issue update_status add_comment get_comments \
  poll_comments request_decision await_decision test_connection
