#!/usr/bin/env bash
# Shared paths, key derivation, and prompt-loading helpers for the
# deepseek-implement skill (Command Code CLI implementation runs, DeepSeek
# 4.1 Flash). Source-only.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${STATE_DIR:=$SKILL_DIR/state}"
export STATE_DIR
mkdir -p "$STATE_DIR"

# Implementation runs on DeepSeek 4.1 Flash via Command Code (`cmd`) by
# default. Override per-run via DEEPSEEK_MODEL. DEEPSEEK_DIR is the
# directory `cmd` runs in (defaults to the caller's cwd, i.e. the repo
# being worked on) -- `cmd` has no --dir flag, the workspace is its cwd.
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek/deepseek-v4.1-flash}"
DEEPSEEK_DIR="${DEEPSEEK_DIR:-$(pwd)}"
export DEEPSEEK_MODEL DEEPSEEK_DIR

# Runs use --yolo: headless `cmd -p` withholds shell_command otherwise, and
# the implementer has to run lint/build/tests. Deny rules still win over
# yolo, but `cmd` only reads them from settings files (no per-run config):
# ~/.commandcode/settings.json, a symlink to commandcode/settings.json in the
# <config-repo> repo. Fail closed if that deny list is missing -- a yolo
# run without it would have no git/rm guard rails but the git-state guard.
PERMISSIONS_FILE="$HOME/.commandcode/settings.json"

require_permissions() {
    if [ ! -r "$PERMISSIONS_FILE" ]; then
        echo "error: $PERMISSIONS_FILE missing or unreadable -- refusing a --yolo run" >&2
        echo "       expected a symlink to <config-repo>/commandcode/settings.json" >&2
        return 1
    fi
    if ! jq -e '(.permissions.deny // []) | length > 0' "$PERMISSIONS_FILE" >/dev/null 2>&1; then
        echo "error: no deny rules in $PERMISSIONS_FILE (or invalid JSON) -- refusing a --yolo run" >&2
        return 1
    fi
}

# One headless `cmd` run in $DEEPSEEK_DIR. $1 = prompt, $2 = events file;
# any further args (e.g. --resume <id>, --name <n>) are passed through.
run_cmd() {
    local prompt="$1" events_file="$2"
    shift 2
    (
        cd "$DEEPSEEK_DIR" &&
        cmd --print "$prompt" \
            --model "$DEEPSEEK_MODEL" \
            --output-format json \
            --trust \
            --skip-onboarding \
            --no-auto-update \
            --yolo \
            --max-turns 150 \
            "$@" \
            </dev/null >"$events_file" 2>"$events_file.stderr"
    )
}

# Session id from a `cmd --output-format json` events file: the final
# result line carries it, run_start does too (survives a max-turns abort).
session_id_from() {
    jq -r 'select(.type=="result") | .sessionId // empty' "$1" 2>/dev/null | tail -1 | grep . ||
        jq -r 'select(.type=="event" and .event.type=="run_start") | .event.sessionId // empty' "$1" 2>/dev/null | head -1
}

# Derive a per-target key from a path-like string. For real paths we
# resolve to absolute; for non-path targets (branch names, labels) we
# sanitize in place. Replace '/' with '__'; force any other
# non-portable characters to '_'.
target_key() {
    local target="$1"
    if [ -e "$target" ]; then
        local abs
        abs="$(realpath -- "$target" 2>/dev/null || readlink -f -- "$target")"
        if [ -z "$abs" ]; then
            echo "error: cannot resolve target path: $target" >&2
            return 1
        fi
        printf '%s' "$abs" | sed 's|^/||; s|/|__|g'
    else
        printf '%s' "$target" | sed 's|^/||; s|/|__|g; s|[^A-Za-z0-9._-]|_|g'
    fi
}

thread_file() {
    printf '%s/%s.thread' "$STATE_DIR" "$(target_key "$1")"
}

review_file() {
    printf '%s/%s.review.txt' "$STATE_DIR" "$(target_key "$1")"
}

events_file() {
    printf '%s/%s.events.ndjson' "$STATE_DIR" "$(target_key "$1")"
}

# Load a prompt template from $1 and substitute {{TARGET}},
# {{EXTRA_PROMPT}} and {{IMPLEMENTER_NOTES}} placeholders with the values
# of the $TARGET / $EXTRA_PROMPT / $IMPLEMENTER_NOTES environment
# variables. Other text passes through verbatim. Writes the substituted
# prompt to stdout.
load_prompt() {
    local tpl="$1"
    if [ ! -f "$tpl" ]; then
        echo "error: prompt template not found: $tpl" >&2
        return 1
    fi
    # Values are passed via ENVIRON (no -v escape processing) and spliced in
    # with index/substr, so '&' or backslashes in notes/targets stay literal.
    awk '
        function sub_all(line, ph, val,    out, i) {
            out = ""
            while ((i = index(line, ph)) > 0) {
                out = out substr(line, 1, i - 1) val
                line = substr(line, i + length(ph))
            }
            return out line
        }
        {
            $0 = sub_all($0, "{{TARGET}}", ENVIRON["TARGET"])
            $0 = sub_all($0, "{{EXTRA_PROMPT}}", ENVIRON["EXTRA_PROMPT"])
            $0 = sub_all($0, "{{IMPLEMENTER_NOTES}}", ENVIRON["IMPLEMENTER_NOTES"])
            print
        }
    ' "$tpl"
}

# --- `cmd --print` exit codes (documented in Command Code's headless
# reference): map them onto this skill's exit codes. Prints a message and
# returns the skill exit code; returns 0 for runs that still produced a
# usable, resumable report (8 = max turns reached).
map_cmd_exit() {
    local rc="$1" events_file="$2"
    case "$rc" in
        0) return 0 ;;
        8) echo "warning: cmd hit --max-turns -- partial run, resume to continue" >&2; return 0 ;;
        5|10) echo "error: DeepSeek/Command Code quota exhausted (cmd rc=$rc)" >&2; return 3 ;;
        3) echo "error: cmd not logged in -- run 'cmd login' (cmd rc=3)" >&2; return 1 ;;
        *)
            echo "error: cmd --print failed (rc=$rc)" >&2
            echo "stderr tail:" >&2
            tail -20 "$events_file.stderr" >&2
            return 1 ;;
    esac
}

# --- Report extraction from a `cmd --output-format json` events file ---
# The last line is the top-level result object {"type":"result",
# "finalText":...}. Writes it to $2 (the report file), falling back to the
# (ANSI-stripped) stderr if the run ended without a result line.
extract_report() {
    local events_file="$1" report_file="$2"
    jq -r 'select(.type=="result") | .finalText // empty' \
        "$events_file" > "$report_file" 2>/dev/null || true
    if [ ! -s "$report_file" ]; then
        sed 's/\x1b\[[0-9;]*m//g' "$events_file.stderr" > "$report_file" 2>/dev/null || true
    fi
}

# --- Usage summary from the result line (Command Code reports no cost) ---
usage_summary() {
    local events_file="$1"
    jq -r 'select(.type=="result") | .usage
        | "usage: in=\(.inputTokens // 0) out=\(.outputTokens // 0) cache_read=\(.cacheReadTokens // 0)"' \
        "$events_file" 2>/dev/null | tail -1 | grep . || echo "usage: (unavailable)"
}

# --- Git-state guard ---
# `cmd`'s shell deny rules are pattern-matching on the command
# string, not a real sandbox -- a clever or accidental invocation could
# still slip a write past them (e.g. via a wrapper script). This guard
# snapshots the git state before the run and compares it after; any
# change (HEAD, branch, stash, tags, staged index) is a hard failure regardless of
# what the report claims. Skips gracefully outside a git repo.

guard_snapshot() {
    local dir="$1"
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "warning: $dir is not a git work tree -- git-state guard disabled" >&2
        echo "no-git"
        return 0
    fi
    local head branch stashes tags staged
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
    branch="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)"
    stashes="$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d ' ')"
    tags="$(git -C "$dir" tag 2>/dev/null | wc -l | tr -d ' ')"
    staged="$(git -C "$dir" diff --cached 2>/dev/null | shasum | cut -c1-12)"
    printf 'head=%s branch=%s stashes=%s tags=%s staged=%s\n' "$head" "$branch" "$stashes" "$tags" "$staged"
}

# Compares two snapshots produced by guard_snapshot. Prints a violation
# message and returns 1 if they differ (and neither is "no-git"); returns
# 0 otherwise.
guard_check() {
    local before="$1" after="$2"
    if [ "$before" = "no-git" ] || [ "$after" = "no-git" ]; then
        return 0
    fi
    if [ "$before" != "$after" ]; then
        echo "GUARD VIOLATION: git state changed during the run" >&2
        echo "  before: $before" >&2
        echo "  after:  $after" >&2
        return 1
    fi
    return 0
}

# Sanity check for the extracted report: an empty report means the run
# produced nothing usable (return 1); a report without the closing tag is
# suspicious (warn, return 0).
check_report() {
    local report_file="$1"
    if [ ! -s "$report_file" ]; then
        echo "error: empty report -- inspect the events file before trusting this run" >&2
        return 1
    fi
    if ! grep -qE '^[[:space:]]*IMPLEMENTATION_(COMPLETE|PARTIAL)[[:space:]]*$' "$report_file"; then
        echo "warning: report has no IMPLEMENTATION_COMPLETE/PARTIAL tag -- treat as PARTIAL and inspect the tree" >&2
    fi
    return 0
}
