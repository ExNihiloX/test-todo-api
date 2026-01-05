#!/usr/bin/env bash
# ralph-lock.sh - Portable file locking using mkdir (works on macOS and Linux)
# mkdir is atomic on all Unix systems, unlike flock which requires GNU coreutils

set -euo pipefail

source "$(dirname "$0")/ralph-config.sh"

# =============================================================================
# LOCK FUNCTIONS
# =============================================================================

# Acquire a lock by creating a directory
# Usage: lock_path=$(acquire_lock "lock_name" [timeout_seconds])
# Returns: lock directory path on success, exits with 1 on timeout
acquire_lock() {
  local lock_name="$1"
  local max_wait="${2:-30}"
  local lock_dir="${LOCK_PREFIX}-${lock_name}"
  local waited=0

  log_debug "Attempting to acquire lock: $lock_name"

  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [[ $waited -ge $max_wait ]]; then
      log_error "Lock acquisition timeout after ${max_wait}s: $lock_name"
      echo "TIMEOUT"
      return 1
    fi
    log_debug "Waiting for lock: $lock_name (${waited}s)"
  done

  # Write PID for debugging
  echo $$ > "$lock_dir/pid"
  echo "$(date -Iseconds)" > "$lock_dir/acquired_at"

  log_debug "Lock acquired: $lock_name"
  echo "$lock_dir"
}

# Release a lock by removing the directory
# Usage: release_lock "/path/to/lock/dir"
release_lock() {
  local lock_dir="$1"

  if [[ -d "$lock_dir" ]]; then
    rm -rf "$lock_dir"
    log_debug "Lock released: $lock_dir"
    return 0
  else
    log_warn "Lock directory not found: $lock_dir"
    return 1
  fi
}

# Check if a lock exists and who holds it
# Usage: check_lock "lock_name"
check_lock() {
  local lock_name="$1"
  local lock_dir="${LOCK_PREFIX}-${lock_name}"

  if [[ -d "$lock_dir" ]]; then
    local pid=""
    local acquired_at=""
    [[ -f "$lock_dir/pid" ]] && pid=$(cat "$lock_dir/pid")
    [[ -f "$lock_dir/acquired_at" ]] && acquired_at=$(cat "$lock_dir/acquired_at")
    echo "LOCKED:pid=$pid,acquired=$acquired_at"
    return 0
  else
    echo "UNLOCKED"
    return 1
  fi
}

# Force release a stale lock (use with caution)
# Usage: force_release_lock "lock_name"
force_release_lock() {
  local lock_name="$1"
  local lock_dir="${LOCK_PREFIX}-${lock_name}"

  if [[ -d "$lock_dir" ]]; then
    log_warn "Force releasing lock: $lock_name"
    rm -rf "$lock_dir"
    return 0
  fi
  return 1
}

# Execute a function while holding a lock
# Usage: with_lock "lock_name" "command to run"
with_lock() {
  local lock_name="$1"
  shift
  local cmd="$*"

  local lock_dir
  lock_dir=$(acquire_lock "$lock_name")

  if [[ "$lock_dir" == "TIMEOUT" ]]; then
    return 1
  fi

  # Ensure lock is released on exit
  trap "release_lock '$lock_dir'" EXIT

  # Run the command
  eval "$cmd"
  local result=$?

  # Release lock
  release_lock "$lock_dir"
  trap - EXIT

  return $result
}

# =============================================================================
# MAIN - CLI interface for testing
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-help}" in
    acquire)
      acquire_lock "${2:-test}" "${3:-30}"
      ;;
    release)
      release_lock "$2"
      ;;
    check)
      check_lock "${2:-test}"
      ;;
    force-release)
      force_release_lock "${2:-test}"
      ;;
    help|*)
      echo "Usage: $0 {acquire|release|check|force-release} [lock_name] [timeout]"
      echo ""
      echo "Commands:"
      echo "  acquire <name> [timeout]  - Acquire a lock (default timeout: 30s)"
      echo "  release <lock_dir>        - Release a lock by directory path"
      echo "  check <name>              - Check if lock exists"
      echo "  force-release <name>      - Force release a stale lock"
      ;;
  esac
fi
