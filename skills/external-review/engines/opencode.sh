#!/usr/bin/env bash
# Engine backend: OpenCode-Go (opencode run)
# Usage: opencode.sh <start|resume|reset|show|quota> --prompt-file <tpl> --target <path> [--model <model>] [--dir <path>] [--notes "..."]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

ACTION="${1:-}"
shift || true

PROMPT_FILE="" TARGET="" MODEL="" NOTES="" EXTRA="" DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
  --prompt-file)
    PROMPT_FILE="$2"
    shift 2
    ;;
  --target)
    TARGET="$2"
    shift 2
    ;;
  --model)
    MODEL="$2"
    shift 2
    ;;
  --dir)
    DIR="$2"
    shift 2
    ;;
  --notes)
    NOTES="$2"
    shift 2
    ;;
  --)
    shift
    EXTRA="${*:-}"
    break
    ;;
  *)
    EXTRA="${EXTRA:+$EXTRA }$1"
    shift
    ;;
  esac
done

: "${MODEL:=opencode-go/glm-5.3-flash}"
: "${DIR:=$(pwd)}"

case "$ACTION" in
start)
  [ -n "$PROMPT_FILE" ] || {
    echo "error: --prompt-file required" >&2
    exit 1
  }
  [ -n "$TARGET" ] || {
    echo "error: --target required" >&2
    exit 1
  }

  THREAD_FILE="$(thread_file "$TARGET")"
  REVIEW_FILE="$(review_file "$TARGET")"
  EVENTS_FILE="$(events_file "$TARGET")"

  if [ -f "$THREAD_FILE" ]; then
    echo "error: review session already exists for $TARGET (session: $(cat "$THREAD_FILE"))" >&2
    echo "       use 'resume' to continue, or 'reset' to start fresh." >&2
    exit 2
  fi

  export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES=""
  PROMPT="$(load_prompt "$PROMPT_FILE")"

  TARGET_KEY="$(target_key "$TARGET")"

  opencode run \
    --format json \
    --model "$MODEL" \
    --dir "$DIR" \
    --title "review-$TARGET_KEY" \
    "$PROMPT" \
    >"$EVENTS_FILE" 2>"$EVENTS_FILE.stderr" || {
    rc=$?
    if grep -qi "rate.limit\|quota\|exceeded\|insufficient\|balance" "$EVENTS_FILE.stderr" 2>/dev/null; then
      echo "error: opencode quota exhausted" >&2
      exit 3
    fi
    echo "error: opencode run failed (rc=$rc)" >&2
    tail -20 "$EVENTS_FILE.stderr" >&2
    exit 1
  }

  SESSION_ID="$(jq -r '.sessionID // empty' "$EVENTS_FILE" 2>/dev/null | head -1)"
  if [ -z "$SESSION_ID" ]; then
    echo "error: no sessionID in opencode output" >&2
    exit 1
  fi
  printf '%s\n' "$SESSION_ID" >"$THREAD_FILE"

  # Extract the review text: text parts of the last assistant message
  # Export to a file first: a direct pipe into jq truncates larger sessions (~64 KB) and yields an empty report.
  opencode export "$SESSION_ID" >"$REVIEW_FILE.export.json" 2>/dev/null || true
  jq -r '.messages[-1].parts[]? | select(.type=="text") | .text' \
    "$REVIEW_FILE.export.json" >"$REVIEW_FILE" 2>/dev/null || true
  rm -f -- "$REVIEW_FILE.export.json"
  [ -s "$REVIEW_FILE" ] || {
    # Fallback: stderr contains the rendered answer
    sed 's/\x1b\[[0-9;]*m//g' "$EVENTS_FILE.stderr" >"$REVIEW_FILE"
  }
  check_review_sanity "$REVIEW_FILE"

  echo "ENGINE=opencode MODEL=$MODEL TARGET=$TARGET"
  echo "session=$SESSION_ID"
  echo "---"
  cat "$REVIEW_FILE"
  ;;

resume)
  [ -n "$PROMPT_FILE" ] || {
    echo "error: --prompt-file required" >&2
    exit 1
  }
  [ -n "$TARGET" ] || {
    echo "error: --target required" >&2
    exit 1
  }

  THREAD_FILE="$(thread_file "$TARGET")"
  REVIEW_FILE="$(review_file "$TARGET")"
  EVENTS_FILE="$(events_file "$TARGET")"

  if [ ! -f "$THREAD_FILE" ]; then
    echo "error: no session for $TARGET — use 'start' first" >&2
    exit 2
  fi
  SESSION_ID="$(cat "$THREAD_FILE")"

  export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES="$NOTES"
  PROMPT="$(load_prompt "$PROMPT_FILE")"

  opencode run \
    --format json \
    --model "$MODEL" \
    --dir "$DIR" \
    --session "$SESSION_ID" --continue \
    "$PROMPT" \
    >"$EVENTS_FILE" 2>"$EVENTS_FILE.stderr" || {
    rc=$?
    if grep -qi "rate.limit\|quota\|exceeded\|insufficient\|balance" "$EVENTS_FILE.stderr" 2>/dev/null; then
      echo "error: opencode quota exhausted" >&2
      exit 3
    fi
    echo "error: opencode run resume failed (rc=$rc)" >&2
    tail -20 "$EVENTS_FILE.stderr" >&2
    exit 1
  }

  opencode export "$SESSION_ID" >"$REVIEW_FILE.export.json" 2>/dev/null || true
  jq -r '.messages[-1].parts[]? | select(.type=="text") | .text' \
    "$REVIEW_FILE.export.json" >"$REVIEW_FILE" 2>/dev/null || true
  rm -f -- "$REVIEW_FILE.export.json"
  [ -s "$REVIEW_FILE" ] || {
    sed 's/\x1b\[[0-9;]*m//g' "$EVENTS_FILE.stderr" >"$REVIEW_FILE"
  }
  check_review_sanity "$REVIEW_FILE"

  echo "ENGINE=opencode MODEL=$MODEL TARGET=$TARGET (resumed)"
  echo "session=$SESSION_ID"
  echo "---"
  cat "$REVIEW_FILE"
  ;;

reset)
  [ -n "$TARGET" ] || {
    echo "error: --target required" >&2
    exit 1
  }
  removed=0
  for f in "$(thread_file "$TARGET")" "$(review_file "$TARGET")" "$(review_file "$TARGET").export.json" "$(events_file "$TARGET")" "$(events_file "$TARGET").stderr"; do
    [ -f "$f" ] && {
      rm -- "$f"
      echo "removed $f"
      removed=$((removed + 1))
    }
  done
  [ "$removed" = 0 ] && echo "no state for $TARGET"
  ;;

show)
  [ -n "$TARGET" ] || {
    echo "error: --target required" >&2
    exit 1
  }
  REVIEW_FILE="$(review_file "$TARGET")"
  [ -f "$REVIEW_FILE" ] || {
    echo "error: no review for $TARGET" >&2
    exit 1
  }
  THREAD_FILE="$(thread_file "$TARGET")"
  [ -f "$THREAD_FILE" ] && echo "session=$(cat "$THREAD_FILE")"
  check_review_sanity "$REVIEW_FILE"
  echo "---"
  cat "$REVIEW_FILE"
  ;;

quota)
  # Real percentage endpoint instead of a cost approximation via `opencode stats`
  # (the old method -- no dedicated limit API was known before,
  # this endpoint simply was not found). The token comes from the same
  # file the `opencode` CLI itself reads it from for opencode-go.
  AUTH_FILE="$HOME/.local/share/opencode/auth.json"
  [ -f "$AUTH_FILE" ] || {
    echo "error: not logged in -- run 'opencode auth login' ($AUTH_FILE missing)" >&2
    exit 1
  }

  OC_TOKEN="$(jq -r '.["opencode-go"].key // empty' "$AUTH_FILE" 2>/dev/null)"
  [ -n "$OC_TOKEN" ] || {
    echo "error: no opencode-go key in $AUTH_FILE" >&2
    exit 1
  }

  USAGE_JSON="$(curl -sS --max-time 10 'https://opencode.ai/zen/go/v1/usage' \
    -H "Authorization: Bearer $OC_TOKEN" 2>/dev/null || true)"
  [ -n "$USAGE_JSON" ] || {
    echo "error: zen/go/v1/usage endpoint produced no output" >&2
    exit 1
  }

  printf '%s' "$USAGE_JSON" | jq -c '
        {
            rolling_pct: (.usage.rolling.percent // 0),
            rolling_status: (.usage.rolling.status // null),
            rolling_resets_at: (.usage.rolling.resetsAt // null),
            weekly_pct: (.usage.weekly.percent // 0),
            weekly_status: (.usage.weekly.status // null),
            weekly_resets_at: (.usage.weekly.resetsAt // null),
            monthly_pct: (.usage.monthly.percent // 0),
            monthly_status: (.usage.monthly.status // null),
            monthly_resets_at: (.usage.monthly.resetsAt // null)
        }
    '
  ;;

*)
  echo "usage: opencode.sh <start|resume|reset|show|quota> --prompt-file <tpl> --target <path> [--model <model>] [--dir <dir>] [--notes '...']" >&2
  exit 64
  ;;
esac
