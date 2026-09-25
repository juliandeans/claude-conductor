#!/usr/bin/env bash
# Engine backend: Command Code CLI (cmd) -- https://commandcode.ai/docs
# Usage: commandcode.sh <start|resume|reset|show|quota> --prompt-file <tpl> --target <path> [--model <model>] [--dir <path>] [--notes "..."]
#
# No documented session resume with a stable ID (unlike Codex/
# OpenCode-Go) -- as with agy.sh, "resume" is a new, stateless run
# with the previous review as context in the prompt, no --continue/--resume.
# Reason: --output-format json is documented only as "NDJSON, one object per line",
# without a sample schema for a session/thread ID field -- a
# guessed field name would be unverified and could silently hit the wrong
# sessions. --no-session makes this explicit and prevents it.
#
# Shell access: cmd --print withholds certain tools in headless mode
# (no --sandbox read-only as with Codex). shell_command is blocked (even
# with --auto-accept), glob/grep need --tools-enable. Solution:
# - git status / git diff are computed in the script beforehand and
#   prepended to the prompt (as with agy.sh), so no shell_command is needed
# - --auto-accept + --trust for read_file/read_directory
# - --tools-enable glob,grep for file search
#
# Setup requirement: the `cmd` CLI needs its OWN login (`cmd login`,
# interactive/browser OAuth) -- separate from $CMD_API_KEY, which only
# secures the provider REST API (e.g. for the pi coding agent). Without
# `cmd login` start/resume/quota fail here, regardless of whether
# CMD_API_KEY is set.
#
# Quota probe (quota action): `cmd status --json` and the documented
# provider REST API provably have NO quota fields
# (see docs/provider-quota-management.md). The solution is an
# undocumented "alpha" endpoint (api.commandcode.ai/alpha/billing/credits),
# found via the open-source project codexbar
# (https://github.com/steipete/codexbar), authenticated with the
# CLI's own token from ~/.commandcode/auth.json (created by `cmd login`,
# not CMD_API_KEY). Undocumented means: it can change at any time without
# warning -- so an outage explicitly counts as available:false, as everywhere
# here, never as a full quota.

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

: "${MODEL:=deepseek/deepseek-v4.1-flash}"
: "${DIR:=$(pwd)}"

command -v cmd >/dev/null 2>&1 || {
  echo "error: command-code CLI (cmd) not found -- npm i -g command-code@latest" >&2
  exit 1
}

# Extract the review text from the NDJSON frames. Verified on 2026-09-01
# against a real run: the last line is the top-level result
# object {"type":"result","finalText":"...",...} (not nested in "event")
# -- matching the docs "NDJSON event frames plus one final
# result line". Fallback to cleaned raw output remains, in case a run
# ends without a "result" line for some reason (e.g. --max-turns abort).
extract_review() {
  local events_file="$1" out_file="$2"
  jq -r 'select(.type=="result") | .finalText // empty' \
    "$events_file" 2>/dev/null >"$out_file"
  [ -s "$out_file" ] || sed 's/\x1b\[[0-9;]*m//g' "$events_file" >"$out_file"
  [ -s "$out_file" ] || sed 's/\x1b\[[0-9;]*m//g' "$events_file.stderr" >"$out_file"
}

prepare_git_context() {
  local dir="$1"
  local git_status git_diff diff_source max_diff_bytes=200000
  git_status="$(cd "$dir" && git status -s 2>/dev/null)" || git_status="(not a git repo)"
  git_diff="$(cd "$dir" && git diff HEAD 2>/dev/null)" || git_diff=""
  diff_source="uncommitted changes (git diff HEAD)"
  if [ -z "$git_diff" ]; then
    git_diff="$(cd "$dir" && git diff '@{u}...HEAD' 2>/dev/null)" || git_diff=""
    diff_source="unpushed commits (git diff @{u}...HEAD)"
    [ -n "$git_diff" ] || git_diff="(no diff available)"
  fi
  # A diff over the limit would fail as a single cmd command-line argument
  # with "Argument list too long" (e.g. when the working tree is clean
  # but the local branch is far ahead of a rarely pushed
  # upstream). Instead of crashing: a short summary instead of the content,
  # the model has full code access via read_file/grep/glob anyway.
  if [ "${#git_diff}" -gt "$max_diff_bytes" ]; then
    local commit_count
    commit_count="$(cd "$dir" && git rev-list --count '@{u}..HEAD' 2>/dev/null)" || commit_count="?"
    git_diff="(diff too large for the prompt context: ${#git_diff} characters from ${diff_source}, ${commit_count} commits ahead of the upstream. Read the relevant code directly via read_file/grep/glob instead.)"
  fi
  cat <<GITEOF
IMPORTANT — TOOL RESTRICTIONS:
shell_command is BLOCKED in this mode. Do NOT attempt to call shell_command —
it will be denied and waste your turns.
You CAN use read_file, read_directory, grep, and glob to inspect source files.

The complete git output is provided below — skip any "To see the change set:
git status / git diff" instructions in the review prompt, the data is here:

GIT STATUS (-s):
${git_status}

GIT DIFF HEAD:
${git_diff}

--- END OF PRE-COMPUTED GIT CONTEXT ---

GITEOF
}

run_cmd() {
  local prompt="$1" events_file="$2"
  local git_context
  git_context="$(prepare_git_context "$DIR")"
  cmd --print "${git_context}${prompt}" \
    --model "$MODEL" \
    --output-format json \
    --add-dir "$DIR" \
    --no-session \
    --auto-accept \
    --trust \
    --tools-enable glob,grep \
    --max-turns 30 \
    >"$events_file" 2>"$events_file.stderr"
}

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
    echo "error: review state already exists for $TARGET" >&2
    echo "       use 'resume' to continue, or 'reset' to start fresh." >&2
    exit 2
  fi

  export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES=""
  PROMPT="$(load_prompt "$PROMPT_FILE")"

  run_cmd "$PROMPT" "$EVENTS_FILE" || {
    rc=$?
    if grep -qi "rate.limit\|quota\|exceeded\|insufficient\|balance\|usage limit" "$EVENTS_FILE.stderr" "$EVENTS_FILE" 2>/dev/null; then
      echo "error: commandcode quota exhausted" >&2
      exit 3
    fi
    echo "error: cmd --print failed (rc=$rc)" >&2
    tail -20 "$EVENTS_FILE.stderr" >&2
    exit 1
  }

  extract_review "$EVENTS_FILE" "$REVIEW_FILE"
  check_review_sanity "$REVIEW_FILE"
  printf 'commandcode-done\n' >"$THREAD_FILE"

  echo "ENGINE=commandcode MODEL=$MODEL TARGET=$TARGET"
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
    echo "error: no session for $TARGET -- use 'start' first" >&2
    exit 2
  fi

  PREV_REVIEW=""
  [ -f "$REVIEW_FILE" ] && PREV_REVIEW="$(cat "$REVIEW_FILE")"

  export TARGET EXTRA_PROMPT="$EXTRA" IMPLEMENTER_NOTES="$NOTES"
  PROMPT="$(load_prompt "$PROMPT_FILE")"

  FULL_PROMPT="PREVIOUS REVIEW:

${PREV_REVIEW}

---

${PROMPT}"

  run_cmd "$FULL_PROMPT" "$EVENTS_FILE" || {
    rc=$?
    if grep -qi "rate.limit\|quota\|exceeded\|insufficient\|balance\|usage limit" "$EVENTS_FILE.stderr" "$EVENTS_FILE" 2>/dev/null; then
      echo "error: commandcode quota exhausted" >&2
      exit 3
    fi
    echo "error: cmd --print resume failed (rc=$rc)" >&2
    tail -20 "$EVENTS_FILE.stderr" >&2
    exit 1
  }

  extract_review "$EVENTS_FILE" "$REVIEW_FILE"
  check_review_sanity "$REVIEW_FILE"

  echo "ENGINE=commandcode MODEL=$MODEL TARGET=$TARGET (resumed -- new run with previous context)"
  echo "---"
  cat "$REVIEW_FILE"
  ;;

reset)
  [ -n "$TARGET" ] || {
    echo "error: --target required" >&2
    exit 1
  }
  removed=0
  for f in "$(thread_file "$TARGET")" "$(review_file "$TARGET")" "$(events_file "$TARGET")" "$(events_file "$TARGET").stderr"; do
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
  check_review_sanity "$REVIEW_FILE"
  echo "ENGINE=commandcode (stateless -- no thread ID)"
  echo "---"
  cat "$REVIEW_FILE"
  ;;

quota)
  # Undocumented alpha endpoint (see comment above) -- the token comes
  # from ~/.commandcode/auth.json (created by `cmd login`), not CMD_API_KEY.
  AUTH_FILE="$HOME/.commandcode/auth.json"
  [ -f "$AUTH_FILE" ] || {
    echo "error: not logged in -- run 'cmd login' ($AUTH_FILE missing)" >&2
    exit 1
  }

  CC_TOKEN="$(jq -r '.apiKey // empty' "$AUTH_FILE" 2>/dev/null)"
  [ -n "$CC_TOKEN" ] || {
    echo "error: no apiKey in $AUTH_FILE" >&2
    exit 1
  }

  BILLING_JSON="$(curl -sS --max-time 10 https://api.commandcode.ai/alpha/billing/credits \
    -H "Authorization: Bearer $CC_TOKEN" -H "x-api-key: $CC_TOKEN" 2>/dev/null || true)"
  [ -n "$BILLING_JSON" ] || {
    echo "error: billing endpoint produced no output" >&2
    exit 1
  }

  # resetAt comes in milliseconds -- normalize to Unix seconds as
  # with the other engines (codex.sh: resets_at also in seconds).
  printf '%s' "$BILLING_JSON" | jq -c '
        {
            authenticated: true,
            weekly_used: (.windowLimits.weekly.used // null),
            weekly_cap: (.windowLimits.weekly.cap // null),
            weekly_exceeded: (.windowLimits.weekly.exceeded // false),
            weekly_resets_at: (if .windowLimits.weekly.resetAt then (.windowLimits.weekly.resetAt / 1000 | floor) else null end),
            five_hour_used: (.windowLimits.fiveHour.used // null),
            five_hour_cap: (.windowLimits.fiveHour.cap // null),
            five_hour_exceeded: (.windowLimits.fiveHour.exceeded // false),
            monthly_credits: (.credits.monthlyCredits // null),
            purchased_credits: (.credits.purchasedCredits // null),
            free_credits: (.credits.freeCredits // null),
            below_threshold: (.credits.belowThreshold // false)
        }
    '
  ;;

*)
  echo "usage: commandcode.sh <start|resume|reset|show|quota> --prompt-file <tpl> --target <path> [--model <model>] [--dir <dir>] [--notes '...']" >&2
  exit 64
  ;;
esac
