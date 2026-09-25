#!/usr/bin/env bash
# agy-run.sh — quota-aware wrapper around the Antigravity CLI (agy).
#
# Builds four rules into code instead of prompts:
#   1. The quota is checked BEFORE every run (/usage provably costs 0 tokens).
#   2. No silent downgrade — every model switch shows up in the summary.
#      If the quota is too tight, the run aborts with exit 3 instead of quietly
#      falling back to a weaker model.
#   3. Workspace scoping is mandatory: --dir must be given, work happens
#      in an empty scratch directory, never in the repo root.
#   4. Full report in a file, only a short version on stdout.
#
# No --mode plan: measured on 2026-08-18 this is a planning mode that writes a
# plan file and leaves the question unanswered — not a read-only switch.
# Write protection instead comes from print mode itself: without a TTY
# nobody can confirm a permission, so every access needing approval is
# automatically refused and the run ends with status=ERROR.
#
# Exit codes:
#   0  success
#   1  invocation, parse or configuration error
#   2  agy ran but reported status != SUCCESS
#   3  quota is insufficient for this task class

set -euo pipefail

AGY_HOME="$HOME/.claude/agy"
RUNS_DIR="$AGY_HOME/runs"
LOG="$RUNS_DIR/runs.log"
mkdir -p "$RUNS_DIR"

die() { printf 'agy-run: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
Usage:
  agy-run.sh --class <breite|gegencheck> --label <slug>
             (--prompt-file <file> | --prompt "<text>")
             (--file <file> [--file ...] --base <directory> | --dir <path> [--dir ...])
             [--schema <file>] [--timeout 10m] [--dry-run]

  --class breite      Condense/review. No verdict needed, independence from
                      Claude irrelevant -> may fall back to the Claude/GPT pool.
  --class gegencheck  Pre-filter before the Sol review. Independence from
                      Claude is the purpose -> falling back to agy-Claude is FORBIDDEN.
  --file / --base     Recommended. Only the named files are placed (as copies) into an
                      empty scratch directory; --base is the root against which the
                      paths are reported repo-relative. Gemini sees nothing else.
  --dir               Alternative, repeatable. The whole directory as workspace
                      (no listing/searching for Gemini — only files with a known path).
  --dry-run           Only check the quota and show the model choice, send nothing.
USAGE
    exit 1
}

CLASS=""; LABEL=""; PROMPT=""; PROMPT_FILE=""; SCHEMA=""; TIMEOUT="10m"; DRY=0
DIRS=(); FILES=(); BASE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --class)       CLASS="${2:-}"; shift 2 ;;
        --label)       LABEL="${2:-}"; shift 2 ;;
        --prompt)      PROMPT="${2:-}"; shift 2 ;;
        --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
        --dir)         DIRS+=("${2:-}"); shift 2 ;;
        --file)        FILES+=("${2:-}"); shift 2 ;;
        --base)        BASE="${2:-}"; shift 2 ;;
        --schema)      SCHEMA="${2:-}"; shift 2 ;;
        --timeout)     TIMEOUT="${2:-}"; shift 2 ;;
        --dry-run)     DRY=1; shift ;;
        -h|--help)     usage ;;
        *)             die "unknown argument: $1" ;;
    esac
done

case "$CLASS" in
    breite|gegencheck) ;;
    *) die "--class must be 'breite' or 'gegencheck' (was: '${CLASS:-empty}')" ;;
esac

[ -n "$LABEL" ] || die "--label missing"
case "$LABEL" in
    *[!A-Za-z0-9._-]*) die "--label may contain only A-Z a-z 0-9 . _ -" ;;
esac

# Workspace scoping is not optional. Without --dir the repo root would be the
# workspace — that is where databases, backups and .env files live.
[ "${#DIRS[@]}" -gt 0 ] || [ "${#FILES[@]}" -gt 0 ] || die "--file or --dir missing. Scoping is mandatory, not a default."

for d in ${DIRS[@]+"${DIRS[@]}"}; do
    [ -d "$d" ] || die "--dir does not point to a directory: $d"
done

# --file: every file must really exist, lie under --base (no escape via
# ../ or symlink) and must not be a secret. The check happens BEFORE copying.
if [ "${#FILES[@]}" -gt 0 ]; then
    [ -n "$BASE" ] && [ -d "$BASE" ] || die "--file needs --base <directory>"
    BASE="$(cd "$BASE" && pwd -P)"
    [ "$BASE" != "/" ] && [ "$BASE" != "$HOME" ] || die "--base must not be / or the home directory: $BASE"
    RELS=()
    for f in "${FILES[@]}"; do
        [ -f "$f" ] || die "--file is not a file: $f"
        [ ! -L "$f" ] || die "--file must not be a symlink: $f"
        abs="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
        case "$abs" in
            "$BASE"/*) rel="${abs#"$BASE"/}" ;;
            *) die "--file lies outside --base ($BASE): $f" ;;
        esac
        case "$(basename "$rel")" in
            .env|.env.*|*.env|*.db|*.sqlite|*.sqlite3|*.pem|*.key|id_rsa*|id_ed25519*|*.p12|*.keystore|credentials*|secrets*)
                die "--file looks like a secret/database and is not shared: $rel" ;;
        esac
        RELS+=("$rel")
    done
fi

if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || die "--prompt-file not found: $PROMPT_FILE"
    PROMPT="$(cat "$PROMPT_FILE")"
fi
[ -n "$PROMPT" ] || die "neither --prompt nor --prompt-file given"
[ -z "$SCHEMA" ] || [ -f "$SCHEMA" ] || die "--schema not found: $SCHEMA"

command -v agy >/dev/null 2>&1 || die "agy not in PATH"
command -v jq  >/dev/null 2>&1 || die "jq not in PATH"

# ------------------------------------------------------------------- Quota
# /usage is a local metadata call: num_turns 0, total_tokens 0.
# Checking costs nothing, so it is checked before every run.
usage_json="$(agy -p "/usage" --output-format json 2>/dev/null || true)"
usage_txt="$(printf '%s' "$usage_json" | jq -r '.response // empty' 2>/dev/null || true)"

[ -n "$usage_txt" ] || die "quota not readable (/usage returned nothing). Aborting instead of guessing."

# Per pool the TIGHTEST of the two windows (week / 5 hours) plus its reset.
pool_state() {
    awk -F'\t' -v p="$1" '
        index($0, p) == 1 {
            pct = $3; gsub(/[^0-9]/, "", pct)
            if (pct == "") next
            if (m == "" || pct + 0 < m + 0) { m = pct; r = $4 }
        }
        END { if (m == "") exit 1; printf "%s %s\n", m, r }
    '
}

gem_state="$(printf '%s\n' "$usage_txt" | pool_state "Gemini Models" || true)"
cla_state="$(printf '%s\n' "$usage_txt" | pool_state "Claude and GPT" || true)"

# A format change at Google must not pass as "all empty": better to fail
# loudly than to take the weakest model just in case.
[ -n "$gem_state" ] || die "quota format not recognized. Check the parser, do not guess. Raw text:
$usage_txt"

GEM_PCT="${gem_state%% *}"; GEM_RESET="${gem_state##* }"
if [ -n "$cla_state" ]; then
    CLA_PCT="${cla_state%% *}"; CLA_RESET="${cla_state##* }"
else
    CLA_PCT=0; CLA_RESET="unknown"
fi

# -------------------------------------------------------------- Model choice
# Fixed to Gemini 3.8 Flash (Medium) for both classes — no ladder, no
# falling back to Claude/GPT. Only condition: the Gemini pool must not be
# completely empty.
MODEL="gemini-3.8-flash-medium"; POOL="Gemini"; STUFE="fix"

if [ "$GEM_PCT" -le 0 ]; then
    {
        echo "QUOTA EXHAUSTED — no run."
        echo "  Class:         $CLASS"
        echo "  Gemini pool:   ${GEM_PCT}% free, reset $GEM_RESET"
        if [ "$CLASS" = "gegencheck" ]; then
            echo "  No falling back to agy-Claude: that would be Claude checking Claude."
            echo "  Options: wait for the reset, or Luna via Codex, or straight to Sol without a pre-filter."
        else
            echo "  Options: wait for the reset, or keep working in the Claude harness."
        fi
        echo "  A 5-hour window is not an outage, just a wait."
    } >&2
    exit 3
fi

if [ "$DRY" -eq 1 ]; then
    printf 'DRY-RUN\n  Class %s\n  Model %s (%s pool, %s)\n  Gemini %s%% (reset %s) · Claude/GPT %s%% (reset %s)\n  Workspace: %s\n' \
        "$CLASS" "$MODEL" "$POOL" "$STUFE" "$GEM_PCT" "$GEM_RESET" "$CLA_PCT" "$CLA_RESET" "${DIRS[*]}"
    exit 0
fi

# -------------------------------------------------------------------- Execute
# Empty scratch workspace: agy pulls its working directory into the workspace.
# If that were the repo root, Gemini would see app.db, fixtures/ and .env.production.
WS="$RUNS_DIR/${LABEL}.ws"
rm -rf "$WS"; mkdir -p "$WS"

# --file mode: Gemini gets exclusively copies of the named files.
# The scratch directory IS then the whole workspace — nothing from the repo beside it.
STAGED=""
if [ "${#FILES[@]}" -gt 0 ]; then
    for i in "${!RELS[@]}"; do
        rel="${RELS[$i]}"
        mkdir -p "$WS/$(dirname "$rel")"
        cp "${FILES[$i]}" "$WS/$rel"
        chmod a-w "$WS/$rel"
        STAGED="${STAGED}  - $WS/$rel  (in repo: $rel)"$'\n'
    done
fi

OUT_JSON="$RUNS_DIR/${LABEL}.json"
OUT_ERR="$RUNS_DIR/${LABEL}.stderr"
REPORT="$RUNS_DIR/${LABEL}.report"

# Fixed preamble before EVERY prompt. Structural constraints do not belong in the
# hands of the calling subagent — if it forgets them, the run dies on a
# refused access and the quota is gone anyway.
DIRLIST=""
for d in ${DIRS[@]+"${DIRS[@]}"}; do DIRLIST="${DIRLIST}  - $(cd "$d" && pwd)"$'\n'; done
[ -z "$STAGED" ] || DIRLIST="${DIRLIST}${STAGED}"

PREAMBLE="WORKING CONDITIONS — binding, read before the task:

1. You work exclusively READ-ONLY. Do not create, change or delete anything.
   Every write attempt is refused and aborts the entire run.
   Report exclusively in your answer, never as a file.

2. You see ONLY these directories or files:
${DIRLIST}
   A read access outside them is denied and likewise aborts the run.
   Do not even try. If you lack the context to answer a question, then
   say so in the coverage field — that is the right answer, not a shortcoming.

3. Use NO shell and no RunCommand (not even cat, rg, find, sed, awk) — every
   shell call is denied and ends the run without an answer. Read files
   exclusively with your file-viewing tool (view_file) using the
   full path from point 2. You cannot list or search directories;
   work only with the files whose path you were given.

   Give file paths repo-relative, not absolute (for files from point 2 the
   repo-relative path is in parentheses).

4. Invent nothing. A finding without a verbatim quote from the file and without a concrete
   failure scenario is not a finding. Finding nothing is a full-fledged,
   expected result — nothing_found = true. Do not pad to look useful.

TASK:

"

args=( -p "${PREAMBLE}${PROMPT}"
       --output-format json
       --model "$MODEL"
       --disable-slash-commands    # prompt content (diffs, logs) must not trigger slash commands
       --print-timeout "$TIMEOUT" )
for d in ${DIRS[@]+"${DIRS[@]}"}; do args+=( --add-dir "$(cd "$d" && pwd)" ); done
[ -z "$STAGED" ] || args+=( --add-dir "$WS" )   # cwd alone does not count as a workspace
[ -n "$SCHEMA" ] && args+=( --json-schema "$SCHEMA" )

start_ts="$(date +%s)"
set +e
( cd "$WS" && agy "${args[@]}" ) >"$OUT_JSON" 2>"$OUT_ERR"
rc=$?
set -e
dur=$(( $(date +%s) - start_ts ))

if [ "$rc" -ne 0 ] || ! jq -e . "$OUT_JSON" >/dev/null 2>&1; then
    {
        echo "agy run failed (exit $rc)."
        echo "stdout: $OUT_JSON"
        echo "stderr: $OUT_ERR"
        head -c 500 "$OUT_ERR" 2>/dev/null
    } >&2
    exit 2
fi

status="$(jq -r '.status // "UNKNOWN"' "$OUT_JSON")"
# agy reports SUCCESS even when a refused shell call ended the run without an
# answer. Empty response + denied_actions is a failure, not a success.
if [ "$status" = "SUCCESS" ] && [ -z "$(jq -r '.response // ""' "$OUT_JSON")" ]; then
    denied="$(jq -r '[.denied_actions // [] | .[] | .display_name] | join(",")' "$OUT_JSON")"
    status="EMPTY${denied:+(denied: $denied)}"
fi
in_tok="$(jq -r '.usage.input_tokens  // 0' "$OUT_JSON")"
out_tok="$(jq -r '.usage.output_tokens // 0' "$OUT_JSON")"
jq -r '.response // ""' "$OUT_JSON" > "$REPORT"

printf '%s\t%s\t%s\t%s\tgem=%s%%\tcla=%s%%\tin=%s\tout=%s\t%ss\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CLASS" "$MODEL" "$status" \
    "$GEM_PCT" "$CLA_PCT" "$in_tok" "$out_tok" "$dur" "$LABEL" >> "$LOG"

if [ "$status" != "SUCCESS" ]; then
    echo "agy reports status=$status — do NOT use the result. Details: $OUT_JSON" >&2
    exit 2
fi

# ------------------------------------------------------------- Short version
# The full report stays in the file. Only what is needed goes into the Claude context.
echo "RUN OK"
echo "  Model:       $MODEL  (${POOL} pool, tier: $STUFE)"
echo "  Quota:       Gemini ${GEM_PCT}% (reset $GEM_RESET) · Claude/GPT ${CLA_PCT}%"
echo "  Usage:       ${in_tok} in / ${out_tok} out, ${dur}s"
echo "  Full report: $REPORT"
if [ -n "$SCHEMA" ] && jq -e . "$REPORT" >/dev/null 2>&1; then
    echo "  --- structured summary ---"
    jq -r '
        "  summary: " + (.summary // "(none)"),
        "  nothing_found: " + ((.nothing_found // false) | tostring),
        "  findings: " + ((.findings // [] | length) | tostring) +
          " (hoch: " + ((.findings // [] | map(select(.severity=="hoch")) | length) | tostring) +
          ", mittel: " + ((.findings // [] | map(select(.severity=="mittel")) | length) | tostring) +
          ", niedrig: " + ((.findings // [] | map(select(.severity=="niedrig")) | length) | tostring) + ")"
    ' "$REPORT"
else
    echo "  --- first 25 lines ---"
    head -25 "$REPORT" | sed 's/^/  /'
fi
if [ "$STUFE" != "voll" ]; then
    echo "  NOTE: not the strongest model of this class (tier: $STUFE) — take it into account when judging." >&2
fi
