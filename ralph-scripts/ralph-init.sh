#!/usr/bin/env bash
# ralph-init.sh - Bootstrap a new project for the full autonomous dev system
#
# This sets up:
#   - PM Agent: Validates specs, breaks down work, reviews code
#   - Engineer Agents: Implement features in parallel
#   - Orchestrator: Coordinates all agents
#   - Linear Integration: Human input when agents are blocked
#
# Usage: ralph-init.sh [project-path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="${1:-.}"

echo "🚀 Initializing Ralph Autonomous Development System"
echo "   Target: $PROJECT_PATH"
echo ""

# Create project directory if needed
mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH"
PROJECT_PATH="$(pwd)"

# =============================================================================
# 1. Copy ralph-scripts
# =============================================================================
echo "📁 Copying ralph-scripts..."
if [[ -d "$SCRIPT_DIR" && "$SCRIPT_DIR" != "$PROJECT_PATH/ralph-scripts" ]]; then
  cp -r "$SCRIPT_DIR" "$PROJECT_PATH/ralph-scripts"
  chmod +x "$PROJECT_PATH/ralph-scripts/"*.sh 2>/dev/null || true
  echo "   ✓ Copied orchestrator, PM, agent, and integration scripts"
else
  echo "   ⚠ ralph-scripts already exists or same directory"
fi

# =============================================================================
# 2. Create .claude/settings.json (permissions for autonomous operation)
# =============================================================================
echo "📝 Creating Claude Code settings..."
mkdir -p "$PROJECT_PATH/.claude"
cat > "$PROJECT_PATH/.claude/settings.json" << 'SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(./ralph-scripts/:*)",
      "Bash(git:*)",
      "Bash(gh:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(node:*)",
      "Bash(python:*)",
      "Bash(pip:*)",
      "Bash(jq:*)",
      "Bash(curl:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(rm:*)",
      "Bash(mv:*)",
      "Bash(cp:*)",
      "Bash(chmod:*)",
      "Bash(echo:*)",
      "Bash(printf:*)",
      "Bash(date:*)",
      "Bash(sleep:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(grep:*)",
      "Bash(find:*)",
      "Bash(wc:*)",
      "Bash(sort:*)",
      "Bash(uniq:*)",
      "Bash(pwd)",
      "Bash(which:*)",
      "Bash(source:*)",
      "Bash(export:*)",
      "Bash(cd:*)",
      "Bash(touch:*)",
      "Bash(sed:*)",
      "Bash(awk:*)",
      "Bash(xargs:*)",
      "Bash(seq:*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "WebFetch",
      "WebSearch",
      "mcp__*"
    ],
    "deny": []
  }
}
SETTINGS
echo "   ✓ Created .claude/settings.json"

# =============================================================================
# 3. Create environment template
# =============================================================================
echo "🔑 Creating environment template..."
cat > "$PROJECT_PATH/.env.example" << 'ENVFILE'
# =============================================================================
# RALPH AUTONOMOUS DEV SYSTEM - Environment Configuration
# =============================================================================

# -----------------------------------------------------------------------------
# LINEAR INTEGRATION (Required for autonomous blocking/unblocking)
# -----------------------------------------------------------------------------
# Get your API key from: https://linear.app/settings/api
LINEAR_API_KEY=lin_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Your team ID (run: ./ralph-scripts/ralph-linear.sh teams)
LINEAR_TEAM_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Optional: Default project for new issues
# LINEAR_PROJECT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Optional: Custom state names (defaults shown)
# LINEAR_STATE_BLOCKED=Blocked
# LINEAR_STATE_IN_PROGRESS=In Progress

# -----------------------------------------------------------------------------
# SLACK INTEGRATION (Optional - for notifications)
# -----------------------------------------------------------------------------
# SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx/xxx/xxx
# SLACK_CHANNEL=#dev-notifications

# -----------------------------------------------------------------------------
# AGENT CONFIGURATION
# -----------------------------------------------------------------------------
# Number of parallel engineer agents (default: 3)
# RALPH_AGENT_COUNT=3

# Enable PM layer for validation (default: false)
# RALPH_WITH_PM=true

# Max hours to wait for human input (default: 6)
# RALPH_MAX_WAIT_HOURS=6
ENVFILE
echo "   ✓ Created .env.example"

# =============================================================================
# 4. Create project structure
# =============================================================================
echo "📂 Creating project structure..."
mkdir -p "$PROJECT_PATH/progress/messages"
mkdir -p "$PROJECT_PATH/progress/schedule"
mkdir -p "$PROJECT_PATH/.claude/cache"

# Create .gitignore
cat > "$PROJECT_PATH/.gitignore" << 'GITIGNORE'
# Environment
.env
.env.local

# Ralph runtime state (regenerated each run)
progress/state.json
progress/cost.log
progress/messages/
progress/schedule/
progress/*.log

# Claude local settings
.claude/settings.local.json
.claude/cache/

# Dependencies
node_modules/
__pycache__/
.venv/
GITIGNORE
echo "   ✓ Created directory structure"

# =============================================================================
# 5. Create CLAUDE.md (project instructions)
# =============================================================================
echo "📖 Creating CLAUDE.md..."
cat > "$PROJECT_PATH/CLAUDE.md" << 'CLAUDEMD'
# Project Instructions for Claude

## Startup

**Always source ~/.zshrc first** to load environment variables (LINEAR_API_KEY, LINEAR_TEAM_ID, etc.):

```bash
source ~/.zshrc
```

Only ask the user if a specific required variable is missing after sourcing.

## System Overview

This project uses the **Ralph Autonomous Development System** with three roles:

### 🎯 Product Manager (PM)
- Validates feature specs before engineering starts
- Breaks down large features into subtasks
- Reviews code before PR creation
- Manages cross-feature dependencies

### 👷 Engineer Agents
- Implement features following TDD/direct/docs workflows
- Work in parallel on independent features
- Create PRs when features are complete
- Signal blockers when stuck

### 🎭 Orchestrator
- Coordinates PM and Engineer agents
- Manages feature claiming and progress
- Handles agent communication
- Reports status

## Autonomous Mode

When working autonomously, use Linear for human input:

```bash
# When you need a decision:
./ralph-scripts/ralph-linear.sh decision "$ISSUE_ID" \
  "Description of what you need" \
  '["Option 1", "Option 2", "Option 3"]' \
  6  # max hours to wait
```

This will:
1. Set the issue to "Blocked"
2. Post your question as a comment
3. Poll for up to 6 hours for a response
4. Parse the response and continue

## Workflow Commands

```bash
# Check project status
./ralph-scripts/ralph-status.sh

# Run orchestrator (flat mode - engineers only)
./ralph-scripts/ralph-orchestrator.sh run

# Run orchestrator (hierarchical - PM + engineers)
./ralph-scripts/ralph-orchestrator.sh --with-pm run

# Claim a feature manually
./ralph-scripts/ralph-claim.sh claim <feature-id> <agent-id>

# Send message to another agent
./ralph-scripts/ralph-message.sh send <target-agent> "<message>"
```

## Key Files

| File | Purpose |
|------|---------|
| `prd.json` | Feature specs for batch work |
| `project.json` | Tech stack, build/test commands |
| `HANDOFF.md` | Human-approved batch scope |
| `progress/state.json` | Runtime progress (git-ignored) |

## Quality Standards

All code must:
- Pass existing tests
- Have tests for new functionality
- Follow project style guide
- Have no linter errors
- Be reasonably documented

## Environment

Required environment variables (should be in ~/.zshrc):
- `LINEAR_API_KEY` - For blocking/unblocking workflow
- `LINEAR_TEAM_ID` - Your Linear team

Always run `source ~/.zshrc` at startup. Only ask user if something specific is missing.
CLAUDEMD
echo "   ✓ Created CLAUDE.md"

# =============================================================================
# 6. Create starter project.json
# =============================================================================
echo "⚙️  Creating project.json template..."
cat > "$PROJECT_PATH/project.json" << 'PROJECTJSON'
{
  "name": "my-project",
  "description": "Project description",
  "tech_stack": {
    "language": "typescript",
    "framework": "express",
    "database": "postgresql",
    "testing": "jest"
  },
  "commands": {
    "install": "npm install",
    "build": "npm run build",
    "test": "npm test",
    "lint": "npm run lint",
    "typecheck": "npm run typecheck",
    "dev": "npm run dev"
  },
  "conventions": {
    "branch_prefix": "feature/",
    "commit_format": "conventional",
    "pr_template": true
  }
}
PROJECTJSON
echo "   ✓ Created project.json template"

# =============================================================================
# 7. Test Linear connection
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -n "${LINEAR_API_KEY:-}" ]]; then
  echo "🔗 Testing Linear connection..."
  if "$PROJECT_PATH/ralph-scripts/ralph-linear.sh" test 2>/dev/null; then
    echo "   ✓ Linear connected!"
  else
    echo "   ✗ Linear connection failed - check API key"
  fi
else
  echo "⚠️  LINEAR_API_KEY not set"
  echo ""
  echo "Setup steps:"
  echo "  1. cp .env.example .env"
  echo "  2. Edit .env with your Linear API key"
  echo "  3. source .env"
  echo "  4. ./ralph-scripts/ralph-linear.sh teams  # get team ID"
  echo "  5. Add LINEAR_TEAM_ID to .env"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Ralph Autonomous Dev System initialized!"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  WORKFLOW                                                               │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│  1. DESIGN PHASE (Interactive)                                          │"
echo "│     - Start Claude: cd $PROJECT_PATH && source .env && claude"
echo "│     - Discuss requirements, answer clarifying questions                 │"
echo "│     - Claude creates prd.json and HANDOFF.md                            │"
echo "│     - You review and approve                                            │"
echo "│                                                                         │"
echo "│  2. BATCH PHASE (Autonomous)                                            │"
echo "│     - Claude runs: ./ralph-scripts/ralph-orchestrator.sh --with-pm run  │"
echo "│     - PM validates specs, engineers implement in parallel               │"
echo "│     - Blocked? Claude posts to Linear, waits for your response          │"
echo "│     - You can walk away for hours                                       │"
echo "│                                                                         │"
echo "│  3. REVIEW PHASE (Interactive)                                          │"
echo "│     - Come back, review PRs together                                    │"
echo "│     - Handle edge cases, merge approved PRs                             │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "Quick start:"
echo "  cd $PROJECT_PATH"
echo "  source .env"
echo "  claude"
echo ""
echo "Then say: \"I want to build [your project idea]\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
