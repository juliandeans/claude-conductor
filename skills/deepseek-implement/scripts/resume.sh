#!/usr/bin/env bash
# Turn 2+: resume the existing Command Code (DeepSeek 4.1 Flash) session for
# <target> with a follow-up prompt. The session id is read from the
# per-target state file written by start.sh.
#
# Usage: resume.sh --prompt-file <tpl> [--notes "..."] <target> [extra prompt text...]
# Exit codes: 0 ok, 1 run failure, 2 no prior session, 3 quota exhausted,
#             4 guard violation, 64 usage.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

PROMPT_FILE=""
IMPLEMENTER_NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt-file)
            PROMPT_FILE="$2"; shift 2 ;;
        --prompt-file=*)
            PROMPT_FILE="${1#*=}"; shift ;;
        --notes)
            IMPLEMENTER_NOTES="$2"; shift 2 ;;
        --notes=*)
            IMPLEMENTER_NOTES="${1#*=}"; shift ;;
        --) shift; break ;;
        -*)
            echo "error: unknown flag: $1" >&2; exit 64 ;;
        *) break ;;
    esac
done

if [ -z "$PROMPT_FILE" ] || [ $# -lt 1 ]; then
    echo "usage: resume.sh --prompt-file <tpl> [--notes '...'] <target> [extra prompt text...]" >&2
    exit 64
fi

TARGET="$1"; shift
EXTRA_PROMPT="${*:-}"
export TARGET EXTRA_PROMPT IMPLEMENTER_NOTES

THREAD_FILE="$(thread_file "$TARGET")"
REPORT_FILE="$(review_file "$TARGET")"
EVENTS_FILE="$(events_file "$TARGET")"

if [ ! -f "$THREAD_FILE" ]; then
    echo "error: no implementation session for $TARGET" >&2
    echo "       run start.sh first." >&2
    exit 2
fi
SESSION_ID="$(cat "$THREAD_FILE")"

PROMPT="$(load_prompt "$PROMPT_FILE")"

require_permissions || exit 1

BEFORE_SNAPSHOT="$(guard_snapshot "$DEEPSEEK_DIR")"

rc=0
run_cmd "$PROMPT" "$EVENTS_FILE" --resume "$SESSION_ID" || rc=$?
AFTER_SNAPSHOT="$(guard_snapshot "$DEEPSEEK_DIR")"

if ! guard_check "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT"; then
    exit 4
fi
map_cmd_exit "$rc" "$EVENTS_FILE" || exit $?

extract_report "$EVENTS_FILE" "$REPORT_FILE"

echo "resumed implementation session for $TARGET"
echo "  session id: $SESSION_ID"
echo "  model:      $DEEPSEEK_MODEL"
echo "  dir:        $DEEPSEEK_DIR"
echo "  report file: $REPORT_FILE"
echo "---"
cat "$REPORT_FILE"
echo "---"
usage_summary "$EVENTS_FILE"

check_report "$REPORT_FILE" || exit 1
