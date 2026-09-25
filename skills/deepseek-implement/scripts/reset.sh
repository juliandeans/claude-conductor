#!/usr/bin/env bash
# Drop the per-target session id, report, and event log so the next
# start.sh begins a fresh DeepSeek session.
#
# Usage: reset.sh <target>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

if [ $# -ne 1 ]; then
    echo "usage: reset.sh <target>" >&2
    exit 64
fi

THREAD_FILE="$(thread_file "$1")"
REVIEW_FILE="$(review_file "$1")"
EVENTS_FILE="$(events_file "$1")"

removed=0
for f in "$THREAD_FILE" "$REVIEW_FILE" "$EVENTS_FILE" "$EVENTS_FILE.stderr"; do
    if [ -f "$f" ]; then
        rm -- "$f"
        echo "removed $f"
        removed=$((removed + 1))
    fi
done

if [ "$removed" = 0 ]; then
    echo "no implementation state on file for $1"
fi
