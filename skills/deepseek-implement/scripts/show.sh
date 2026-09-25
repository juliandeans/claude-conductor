#!/usr/bin/env bash
# Show the most recent report for <target> without re-running DeepSeek.
# Useful when the conversation has scrolled past the report output.
#
# Usage: show.sh <target>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

if [ $# -ne 1 ]; then
    echo "usage: show.sh <target>" >&2
    exit 64
fi

REVIEW_FILE="$(review_file "$1")"
THREAD_FILE="$(thread_file "$1")"
EVENTS_FILE="$(events_file "$1")"

if [ ! -f "$REVIEW_FILE" ]; then
    echo "error: no report on file for $1" >&2
    exit 1
fi

if [ -f "$THREAD_FILE" ]; then
    echo "session id: $(cat "$THREAD_FILE")"
fi
echo "report file: $REVIEW_FILE"
echo "---"
cat "$REVIEW_FILE"
if [ -f "$EVENTS_FILE" ]; then
    echo "---"
    usage_summary "$EVENTS_FILE"
fi
