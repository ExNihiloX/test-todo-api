#!/usr/bin/env bash
# ralph-poll-loop.sh - Loop polling until response received
# Auto-approved when called as ./ralph-scripts/ralph-poll-loop.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-linear.sh"

ISSUE_ID="$1"
SINCE="$2"
MAX_ITERATIONS="${3:-180}"  # 180 × 2 min = 6 hours
POLL_TIMEOUT="${4:-120}"    # 2 minutes per poll
POLL_INTERVAL="${5:-30}"    # 30 sec between checks within poll

echo "Starting poll loop for issue $ISSUE_ID"
echo "Max duration: ~$((MAX_ITERATIONS * POLL_TIMEOUT / 60)) minutes"
echo "Waiting for response since: $SINCE"
echo "---"

for ((i=1; i<=MAX_ITERATIONS; i++)); do
    echo "[$(date '+%H:%M:%S')] Poll attempt $i/$MAX_ITERATIONS"

    result=$(poll_comments "$ISSUE_ID" "$SINCE" "$POLL_TIMEOUT" "$POLL_INTERVAL" 2>&1) || true

    if [[ "$result" != "TIMEOUT" && -n "$result" && "$result" != "null" ]]; then
        echo "---"
        echo "RESPONSE_RECEIVED"
        echo "$result"
        exit 0
    fi
done

echo "---"
echo "MAX_ITERATIONS_REACHED"
exit 1
