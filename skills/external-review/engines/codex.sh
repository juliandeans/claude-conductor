#!/usr/bin/env bash
# Engine backend: Codex CLI (codex exec)
# Usage: codex.sh <start|resume|reset|show|quota> --prompt-file <tpl> --target <path> [--model <model>] [--notes "..."]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

ACTION="${1:-}"; shift || true

PROMPT_FILE="" TARGET="" MODEL="" NOTES="" EXTRA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
        --target)      TARGET="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --notes)       NOTES="$2"; shift 2 ;;
        --)            shift; EXTRA="${*:-}"; break ;;
        *)             EXTRA="${EXTRA:+$EXTRA }$1"; shift ;;
    esac
done

: "${MODEL:=gpt-5.6-luna}"
# The reasoning-effort default depends on the model: gpt-6-astra deliberately
# runs at medium (the user's choice -- Astra should not run at xhigh like Sol),
# all other models (Luna, Sol) stay at xhigh. CODEX_EFFORT still overrides
# this explicitly, should it ever be needed.
case "$MODEL" in
    *astra*) DEFAULT_EFFORT="medium" ;;
    *)       DEFAULT_EFFORT="xhigh" ;;
esac
EFFORT="${CODEX_EFFORT:-$DEFAULT_EFFORT}"

case "$ACTION" in
start)
    [ -n "$PROMPT_FILE" ] || { echo "error: --prompt-file required" >&2; exit 1; }
    [ -n "$TARGET" ]      || { echo "error: --target required" >&2; exit 1; }

    THREAD_FILE="$(thread_file "$TARGET")"
    REVIEW_FILE="$(review_file "$TARGET")"
    EVENTS_FILE="$(events_file "$TARGET")"

    if [ -f "$THREAD_FILE" ]; then
        echo "error: review session already exists for $TARGET (thread: $(cat "$THREAD_FILE"))" >&2
        echo "       use 'resume' to continue, or 'reset' to start fresh." >&2
        exit 2
    fi

    export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES=""
    PROMPT="$(load_prompt "$PROMPT_FILE")"

    codex exec \
        --json --skip-git-repo-check --sandbox read-only --color never \
        -c model="$MODEL" -c model_reasoning_effort="$EFFORT" \
        -o "$REVIEW_FILE" "$PROMPT" \
        </dev/null >"$EVENTS_FILE" 2>"$EVENTS_FILE.stderr" || {
            rc=$?
            if grep -qi "rate.limit\|quota\|exceeded\|capacity" "$EVENTS_FILE.stderr" 2>/dev/null; then
                echo "error: codex quota exhausted" >&2; exit 3
            fi
            echo "error: codex exec failed (rc=$rc)" >&2
            tail -20 "$EVENTS_FILE.stderr" >&2; exit 1
        }

    THREAD_ID="$(jq -r 'select(.type == "thread.started") | .thread_id' "$EVENTS_FILE" 2>/dev/null | head -1)"
    if [ -z "$THREAD_ID" ] || [ "$THREAD_ID" = "null" ]; then
        echo "error: no thread.started event in $EVENTS_FILE" >&2; exit 1
    fi
    printf '%s\n' "$THREAD_ID" > "$THREAD_FILE"
    check_review_sanity "$REVIEW_FILE"

    echo "ENGINE=codex MODEL=$MODEL TARGET=$TARGET"
    echo "thread=$THREAD_ID"
    echo "---"
    cat "$REVIEW_FILE"
    ;;

resume)
    [ -n "$PROMPT_FILE" ] || { echo "error: --prompt-file required" >&2; exit 1; }
    [ -n "$TARGET" ]      || { echo "error: --target required" >&2; exit 1; }

    THREAD_FILE="$(thread_file "$TARGET")"
    REVIEW_FILE="$(review_file "$TARGET")"
    EVENTS_FILE="$(events_file "$TARGET")"

    if [ ! -f "$THREAD_FILE" ]; then
        echo "error: no session for $TARGET — use 'start' first" >&2; exit 2
    fi
    THREAD_ID="$(cat "$THREAD_FILE")"

    export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES="$NOTES"
    PROMPT="$(load_prompt "$PROMPT_FILE")"

    codex exec resume "$THREAD_ID" \
        --skip-git-repo-check --json \
        -c model="$MODEL" -c model_reasoning_effort="$EFFORT" \
        -o "$REVIEW_FILE" "$PROMPT" \
        </dev/null >"$EVENTS_FILE" 2>"$EVENTS_FILE.stderr" || {
            rc=$?
            if grep -qi "rate.limit\|quota\|exceeded\|capacity" "$EVENTS_FILE.stderr" 2>/dev/null; then
                echo "error: codex quota exhausted" >&2; exit 3
            fi
            echo "error: codex exec resume failed (rc=$rc)" >&2
            tail -20 "$EVENTS_FILE.stderr" >&2; exit 1
        }

    check_review_sanity "$REVIEW_FILE"
    echo "ENGINE=codex MODEL=$MODEL TARGET=$TARGET (resumed)"
    echo "thread=$THREAD_ID"
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
    THREAD_FILE="$(thread_file "$TARGET")"
    [ -f "$THREAD_FILE" ] && echo "thread=$(cat "$THREAD_FILE")"
    check_review_sanity "$REVIEW_FILE"
    echo "---"
    cat "$REVIEW_FILE"
    ;;

quota)
    # Direct REST call against ChatGPT's own backend instead of JSON-RPC via
    # `codex app-server --stdio` -- much simpler, same 0-token cost,
    # additionally returns fields the JSON-RPC response does not have (plan,
    # approx. remaining messages, spend-control status). Token/account ID
    # come from the same file the `codex` CLI itself reads them from.
    AUTH_FILE="$HOME/.codex/auth.json"
    [ -f "$AUTH_FILE" ] || { echo "error: not logged in -- run 'codex login' ($AUTH_FILE missing)" >&2; exit 1; }

    CODEX_ACCESS_TOKEN="$(jq -r '.tokens.access_token // empty' "$AUTH_FILE" 2>/dev/null)"
    CODEX_ACCOUNT_ID="$(jq -r '.tokens.account_id // empty' "$AUTH_FILE" 2>/dev/null)"
    if [ -z "$CODEX_ACCESS_TOKEN" ] || [ -z "$CODEX_ACCOUNT_ID" ]; then
        echo "error: no access_token/account_id in $AUTH_FILE" >&2; exit 1
    fi

    USAGE_JSON="$(curl -sS --max-time 10 'https://chatgpt.com/backend-api/wham/usage' \
        -H "Authorization: Bearer $CODEX_ACCESS_TOKEN" \
        -H "ChatGPT-Account-Id: $CODEX_ACCOUNT_ID" \
        -H 'User-Agent: codex-cli' \
        -H 'Accept: application/json' 2>/dev/null || true)"
    [ -n "$USAGE_JSON" ] || { echo "error: wham/usage endpoint produced no output" >&2; exit 1; }

    # The expiry date of a bonus reset credit is NOT in this REST response
    # (only available_count, no expiresAt) -- the existing
    # JSON-RPC probe has exactly that field, so call it additionally for
    # enrichment instead of discarding it. Costs one short subprocess extra,
    # but still 0 tokens.
    EXPIRY_JSON="$(python3 "$SCRIPT_DIR/codex_quota_probe.py" 2>/dev/null || echo '{}')"
    CREDIT_EXPIRES_AT="$(printf '%s' "$EXPIRY_JSON" | jq -r '.reset_credit_expires_at // empty' 2>/dev/null)"

    printf '%s' "$USAGE_JSON" | jq -c --arg exp "$CREDIT_EXPIRES_AT" '
        {
            used_pct_primary: (.rate_limit.primary_window.used_percent // 0),
            resets_at_primary: (.rate_limit.primary_window.reset_at),
            used_pct_secondary: (.rate_limit.secondary_window.used_percent // 0),
            resets_at_secondary: (.rate_limit.secondary_window.reset_at),
            reset_credits_available: (.rate_limit_reset_credits.available_count // 0),
            reset_credit_expires_at: (if $exp == "" then null else ($exp | tonumber) end),
            plan_type: .plan_type,
            credit_balance: (.credits.balance // null),
            approx_local_messages: (.credits.approx_local_messages // null),
            approx_cloud_messages: (.credits.approx_cloud_messages // null),
            spend_control_reached: (.spend_control.reached // false)
        }
    '
    ;;

*)
    echo "usage: codex.sh <start|resume|reset|show|quota> --prompt-file <tpl> --target <path> [--model <model>] [--notes '...']" >&2
    exit 64
    ;;
esac
