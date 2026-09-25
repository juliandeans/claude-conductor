#!/usr/bin/env bash
# Engine backend: Antigravity (agy via agy-run.sh)
# Usage: agy.sh <start|resume|reset|show> --prompt-file <tpl> --target <path> [--dir <path>...] [--notes "..."]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

AGY_RUN="$HOME/.claude/agy/agy-run.sh"
[ -x "$AGY_RUN" ] || { echo "error: agy-run.sh not found at $AGY_RUN" >&2; exit 1; }

ACTION="${1:-}"; shift || true

PROMPT_FILE="" TARGET="" NOTES="" EXTRA=""
DIRS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
        --target)      TARGET="$2"; shift 2 ;;
        --dir)         DIRS+=("$2"); shift 2 ;;
        --notes)       NOTES="$2"; shift 2 ;;
        --model)       shift 2 ;;  # agy-run.sh chooses the model itself
        --)            shift; EXTRA="${*:-}"; break ;;
        *)             EXTRA="${EXTRA:+$EXTRA }$1"; shift ;;
    esac
done

# Default: current directory
[ "${#DIRS[@]}" -gt 0 ] || DIRS=("$(pwd)")

case "$ACTION" in
start)
    [ -n "$PROMPT_FILE" ] || { echo "error: --prompt-file required" >&2; exit 1; }
    [ -n "$TARGET" ]      || { echo "error: --target required" >&2; exit 1; }

    REVIEW_FILE="$(review_file "$TARGET")"
    EVENTS_FILE="$(events_file "$TARGET")"
    TARGET_KEY="$(target_key "$TARGET")"

    # Thread file is used by agy as a marker (no real resume)
    THREAD_FILE="$(thread_file "$TARGET")"
    if [ -f "$THREAD_FILE" ]; then
        echo "error: review state already exists for $TARGET" >&2
        echo "       use 'resume' to continue, or 'reset' to start fresh." >&2
        exit 2
    fi

    export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES=""
    PROMPT="$(load_prompt "$PROMPT_FILE")"

    PROMPT_TMP="$STATE_DIR/${TARGET_KEY}.prompt.tmp"
    printf '%s\n' "$PROMPT" > "$PROMPT_TMP"

    DIR_ARGS=()
    for d in "${DIRS[@]}"; do DIR_ARGS+=("--dir" "$d"); done

    "$AGY_RUN" \
        --class breite \
        --label "review-$TARGET_KEY" \
        --prompt-file "$PROMPT_TMP" \
        "${DIR_ARGS[@]}" \
        > "$EVENTS_FILE" 2>"$EVENTS_FILE.stderr" || {
            rc=$?
            rm -f "$PROMPT_TMP"
            [ "$rc" -eq 3 ] && { echo "error: agy quota exhausted" >&2; exit 3; }
            echo "error: agy-run.sh failed (rc=$rc)" >&2
            tail -20 "$EVENTS_FILE.stderr" >&2; exit 1
        }

    rm -f "$PROMPT_TMP"

    # agy-run.sh writes the full report to ~/.claude/agy/runs/<label>.report
    AGY_REPORT="$HOME/.claude/agy/runs/review-${TARGET_KEY}.report"
    if [ -f "$AGY_REPORT" ]; then
        cp "$AGY_REPORT" "$REVIEW_FILE"
    else
        # Fallback: stdout of agy-run.sh (short version)
        cp "$EVENTS_FILE" "$REVIEW_FILE"
    fi
    check_review_sanity "$REVIEW_FILE"

    printf 'agy-done\n' > "$THREAD_FILE"

    echo "ENGINE=agy TARGET=$TARGET"
    echo "---"
    cat "$REVIEW_FILE"
    ;;

resume)
    [ -n "$PROMPT_FILE" ] || { echo "error: --prompt-file required" >&2; exit 1; }
    [ -n "$TARGET" ]      || { echo "error: --target required" >&2; exit 1; }

    REVIEW_FILE="$(review_file "$TARGET")"
    EVENTS_FILE="$(events_file "$TARGET")"
    TARGET_KEY="$(target_key "$TARGET")"
    THREAD_FILE="$(thread_file "$TARGET")"

    if [ ! -f "$THREAD_FILE" ]; then
        echo "error: no session for $TARGET — use 'start' first" >&2; exit 2
    fi

    PREV_REVIEW=""
    [ -f "$REVIEW_FILE" ] && PREV_REVIEW="$(cat "$REVIEW_FILE")"

    export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES="$NOTES"
    PROMPT="$(load_prompt "$PROMPT_FILE")"

    # agy has no real resume — new run with the previous review as context
    FULL_PROMPT="PREVIOUS REVIEW:

${PREV_REVIEW}

---

${PROMPT}"

    PROMPT_TMP="$STATE_DIR/${TARGET_KEY}.prompt.tmp"
    printf '%s\n' "$FULL_PROMPT" > "$PROMPT_TMP"

    DIR_ARGS=()
    for d in "${DIRS[@]}"; do DIR_ARGS+=("--dir" "$d"); done

    "$AGY_RUN" \
        --class breite \
        --label "review-$TARGET_KEY" \
        --prompt-file "$PROMPT_TMP" \
        "${DIR_ARGS[@]}" \
        > "$EVENTS_FILE" 2>"$EVENTS_FILE.stderr" || {
            rc=$?
            rm -f "$PROMPT_TMP"
            [ "$rc" -eq 3 ] && { echo "error: agy quota exhausted" >&2; exit 3; }
            echo "error: agy-run.sh failed (rc=$rc)" >&2
            tail -20 "$EVENTS_FILE.stderr" >&2; exit 1
        }

    rm -f "$PROMPT_TMP"

    AGY_REPORT="$HOME/.claude/agy/runs/review-${TARGET_KEY}.report"
    if [ -f "$AGY_REPORT" ]; then
        cp "$AGY_REPORT" "$REVIEW_FILE"
    else
        cp "$EVENTS_FILE" "$REVIEW_FILE"
    fi
    check_review_sanity "$REVIEW_FILE"

    echo "ENGINE=agy TARGET=$TARGET (resumed — new run with previous context)"
    echo "---"
    cat "$REVIEW_FILE"
    ;;

reset)
    [ -n "$TARGET" ] || { echo "error: --target required" >&2; exit 1; }
    removed=0
    for f in "$(thread_file "$TARGET")" "$(review_file "$TARGET")" "$(events_file "$TARGET")" "$(events_file "$TARGET").stderr"; do
        [ -f "$f" ] && { rm -- "$f"; echo "removed $f"; removed=$((removed + 1)); }
    done
    [ "$removed" = 0 ] && echo "no state for $TARGET"
    ;;

show)
    [ -n "$TARGET" ] || { echo "error: --target required" >&2; exit 1; }
    REVIEW_FILE="$(review_file "$TARGET")"
    [ -f "$REVIEW_FILE" ] || { echo "error: no review for $TARGET" >&2; exit 1; }
    check_review_sanity "$REVIEW_FILE"
    echo "ENGINE=agy (stateless — no thread ID)"
    echo "---"
    cat "$REVIEW_FILE"
    ;;

*)
    echo "usage: agy.sh <start|resume|reset|show> --prompt-file <tpl> --target <path> [--dir <dir>...] [--notes '...']" >&2
    exit 64
    ;;
esac
