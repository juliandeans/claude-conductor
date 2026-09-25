#!/usr/bin/env bash
# Turn 1: start a fresh Command Code (DeepSeek 4.1 Flash) IMPLEMENTATION
# session for <target>, capture the session id, and write the final report
# to the per-target report file.
#
# Unlike codex-implement's --sandbox workspace-write, `cmd` has no real
# sandbox -- runs use --yolo, limited by the deny rules in
# ~/.commandcode/settings.json (pattern rules, not a jail). A git-state
# guard runs around the call as a backstop; see _common.sh.
#
# Usage: start.sh --prompt-file <tpl> <target> [custom instructions…]
# Exit codes: 0 ok, 1 run failure, 2 session already exists,
#             3 quota exhausted, 4 guard violation, 64 usage.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

PROMPT_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt-file)
            PROMPT_FILE="$2"; shift 2 ;;
        --prompt-file=*)
            PROMPT_FILE="${1#*=}"; shift ;;
        --) shift; break ;;
        -*)
            echo "error: unknown flag: $1" >&2; exit 64 ;;
        *) break ;;
    esac
done

if [ -z "$PROMPT_FILE" ] || [ $# -lt 1 ]; then
    echo "usage: start.sh --prompt-file <tpl> <target> [custom instructions…]" >&2
    exit 64
fi

TARGET="$1"; shift
EXTRA_PROMPT="${*:-}"
IMPLEMENTER_NOTES=""
export TARGET EXTRA_PROMPT IMPLEMENTER_NOTES

THREAD_FILE="$(thread_file "$TARGET")"
REPORT_FILE="$(review_file "$TARGET")"
EVENTS_FILE="$(events_file "$TARGET")"

if [ -f "$THREAD_FILE" ]; then
    echo "error: implementation session already exists for $TARGET" >&2
    echo "       session id: $(cat "$THREAD_FILE")" >&2
    echo "       run resume.sh to continue, or reset.sh to start fresh." >&2
    exit 2
fi

PROMPT="$(load_prompt "$PROMPT_FILE")"
TARGET_KEY="$(target_key "$TARGET")"

require_permissions || exit 1

BEFORE_SNAPSHOT="$(guard_snapshot "$DEEPSEEK_DIR")"

rc=0
run_cmd "$PROMPT" "$EVENTS_FILE" --name "implement-$TARGET_KEY" || rc=$?
AFTER_SNAPSHOT="$(guard_snapshot "$DEEPSEEK_DIR")"

# Save the session id even after a failed/aborted run so resume.sh can pick
# the work up again.
SESSION_ID="$(session_id_from "$EVENTS_FILE")" || true
if [ -n "$SESSION_ID" ]; then
    printf '%s\n' "$SESSION_ID" > "$THREAD_FILE"
fi

if ! guard_check "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT"; then
    exit 4
fi
map_cmd_exit "$rc" "$EVENTS_FILE" || exit $?

if [ -z "$SESSION_ID" ]; then
    echo "error: no session id in cmd output" >&2
    echo "first 20 events:" >&2
    head -20 "$EVENTS_FILE" >&2
    exit 1
fi

extract_report "$EVENTS_FILE" "$REPORT_FILE"

echo "started implementation session for $TARGET"
echo "  session id: $SESSION_ID"
echo "  model:      $DEEPSEEK_MODEL"
echo "  dir:        $DEEPSEEK_DIR"
echo "  report file: $REPORT_FILE"
echo "---"
cat "$REPORT_FILE"
echo "---"
usage_summary "$EVENTS_FILE"

check_report "$REPORT_FILE" || exit 1
