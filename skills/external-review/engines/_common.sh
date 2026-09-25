#!/usr/bin/env bash
# Shared helpers for all external-review engine backends.
# Source-only — do not execute directly.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${STATE_DIR:=$SKILL_DIR/state}"
export STATE_DIR
mkdir -p "$STATE_DIR"

# --- Target key derivation (from codex _common.sh) ---

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

# --- Engine name from the filename of the calling script (e.g. "codex"
# for codex.sh) -- appends thread/review/events files per engine,
# kept separate, to the same target key. Prevents two engines on the
# same target path from overwriting each other's state files
# when they run for the same target (engine switch on quota
# exhaustion, or deliberately several engines against the same plan).
# Two different MODELS of the same engine for the same target (e.g.
# CommandCode once with Mimo, once with GLM-5.3-Flash) are NOT
# separated by this -- keep using different --target labels for that.
engine_name() { basename "${0}" .sh; }

thread_file() { printf '%s/%s.%s.thread' "$STATE_DIR" "$(target_key "$1")" "$(engine_name)"; }
review_file() { printf '%s/%s.%s.review.txt' "$STATE_DIR" "$(target_key "$1")" "$(engine_name)"; }
events_file() { printf '%s/%s.%s.events.ndjson' "$STATE_DIR" "$(target_key "$1")" "$(engine_name)"; }

# --- Sanity-check the review result ---
#
# Catches a concretely observed failure mode (2026-09-08, CommandCode/
# GLM): if the model, mid-turn, looks for a file outside the permitted
# directory (e.g. a project-specific checklist that does not exist in this
# project), the sandbox refuses it with
# permission_denied -- but the CLI itself still exits with
# exit code 0, because the error affected only the turn, not the process. The
# result is a short fragment instead of a real review, and at
# first glance looks like a terse but valid result. Without a look
# into the events file this would easily have been taken for a result.
# The same class of error can occur in any engine that extracts review text
# from a JSON response (all four here) -- hence centrally here
# instead of only for CommandCode.
check_review_sanity() {
    local review_file="$1"
    local len
    len="$(wc -c < "$review_file" 2>/dev/null | tr -d ' ')"
    if [ "${len:-0}" -lt 200 ] || grep -qil "permission.denied\|access.*denied" "$review_file" 2>/dev/null; then
        echo "warning: review result looks aborted or suspiciously short (${len:-0} bytes) -- before trusting it, check the events file before adopting the final verdict (APPROVED/REQUEST_CHANGES/...)." >&2
    fi
}

# --- Prompt template loading ---

load_prompt() {
    local tpl="$1"
    if [ ! -f "$tpl" ]; then
        echo "error: prompt template not found: $tpl" >&2
        return 1
    fi
    awk -v target="${TARGET-}" -v extra="${EXTRA_PROMPT-}" -v notes="${IMPLEMENTER_NOTES-}" '
        {
            gsub(/\{\{TARGET\}\}/, target)
            gsub(/\{\{EXTRA_PROMPT\}\}/, extra)
            gsub(/\{\{IMPLEMENTER_NOTES\}\}/, notes)
            print
        }
    ' "$tpl"
}
