#!/usr/bin/env bash
# agy-stdin.sh — thin stdin wrapper around the Antigravity CLI (agy) for
# pi subagents (external-cli with promptDelivery: stdin).
#
# Baked in as in agy-run.sh (rule 1 + 2):
#   1. The quota is checked BEFORE every run (/usage costs 0 tokens).
#   2. No silent downgrade — with an empty Gemini pool the run aborts with
#      exit 3 instead of falling back to a weaker model.
#
# The prompt comes in via stdin (that is how the pi external-cli runner passes it),
# the answer goes out as full JSON on stdout — the runner takes
# stdout as the result. Read protection comes from print mode itself: without a
# TTY every access needing approval is refused.
#
# Invocation:  agy-stdin.sh [extra agy flags...]
#              Prompt via stdin.
# Exit:        0 OK · 1 invocation/configuration error · 2 status != SUCCESS
#              (via agy) · 3 quota is insufficient
set -euo pipefail

MODEL="gemini-3.8-flash-medium"
PRINT_TIMEOUT="10m"

die() {
    printf 'agy-stdin: %s\n' "$*" >&2
    exit 1
}

command -v agy >/dev/null 2>&1 || die "agy not in PATH"
command -v jq >/dev/null 2>&1 || die "jq not in PATH"
command -v awk >/dev/null 2>&1 || die "awk not in PATH"

PROMPT="$(cat)"
[ -n "$PROMPT" ] || die "no prompt received via stdin"

# ------------------------------------------------------------------- Quota
# /usage is a local metadata call: num_turns 0, total_tokens 0.
usage_json="$(agy -p "/usage" --output-format json 2>/dev/null || true)"
usage_txt="$(printf '%s' "$usage_json" | jq -r '.response // empty' 2>/dev/null || true)"

[ -n "$usage_txt" ] || die "quota not readable (/usage returned nothing). Aborting instead of guessing."

# Per pool the TIGHTEST of the two windows (week / 5 hours) plus its reset.
pool_state() {
    awk -F'\t' -v p="$1" '
        index($0, p) == 1 {
            pct = $3; gsub(/[^0-9]/, "", pct)
            if (m == "" || pct + 0 < m + 0) { m = pct; r = $4 }
        }
        END { if (m == "") exit 1; printf "%s %s\n", m, r }
    '
}

gem_state="$(printf '%s\n' "$usage_txt" | pool_state "Gemini Models" || true)"

# A format change at Google must not pass as "all empty": better to fail
# loudly than to take the weakest model just in case.
[ -n "$gem_state" ] || die "quota format not recognized. Check the parser, do not guess. Raw text:
$usage_txt"

GEM_PCT="${gem_state%% *}"
if [ "$GEM_PCT" -le 0 ]; then
    {
        echo "QUOTA EXHAUSTED — no agy subagent run."
        echo "  Model:       $MODEL"
        echo "  Gemini pool: ${GEM_PCT}% free, reset ${gem_state##* }"
        echo "  Options: wait for the reset, or use another engine in the Claude harness."
    } >&2
    exit 3
fi

# -------------------------------------------------------------------- Execute
# Pass the prompt via stdin again: "cat" drained the pipe, with EOF stdin
# agy would fall into interactive mode and die on the missing TTY.
# No exec, so that the status can be checked (rule 2: no silent
# error — status != SUCCESS aborts with exit 2).
OUT_JSON="$(mktemp)"
trap 'rm -f "$OUT_JSON"' EXIT

printf '%s' "$PROMPT" | agy \
    --output-format json \
    --disable-slash-commands \
    --model "$MODEL" \
    --print-timeout "$PRINT_TIMEOUT" \
    "$@" >"$OUT_JSON"
rc=$?

if [ "$rc" -ne 0 ] || ! jq -e . "$OUT_JSON" >/dev/null 2>&1; then
    {
        echo "agy run failed (exit $rc)."
        head -c 500 "$OUT_JSON" 2>/dev/null
    } >&2
    exit "${rc:-1}"
fi

status="$(jq -r '.status // "UNKNOWN"' "$OUT_JSON")"
if [ "$status" != "SUCCESS" ]; then
    error="$(jq -r '.error // ""' "$OUT_JSON")"
    echo "agy reports status=$status — do NOT use the result. ${error:+Error: $error}" >&2
    exit 2
fi

cat "$OUT_JSON"
