#!/usr/bin/env bash
# guard-bash.sh — PreToolUse guard for the Gemini subagents.
#
# The frontmatter field `tools:` cannot restrict Bash to a single command
# (only whole tools). This hook closes that gap:
# it lets only agy-run.sh through and refuses everything else.
#
# Allowlist, not denylist: what is not expressly allowed is refused.

set -euo pipefail

WRAPPER_ABS="$HOME/.claude/agy/agy-run.sh"

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""')"

# Only check Bash calls; everything else is governed by the agent's tools allowlist.
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

deny() {
    jq -n --arg r "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# Chaining and redirection would defeat the allowlist
# (e.g. "agy-run.sh … ; rm -rf …").
case "$cmd" in
    *';'*|*'|'*|*'&'*|*'`'*|*'>'*|*'<'*|*'$('*)
        deny "Chaining/redirection is blocked for this subagent. Exactly one call of agy-run.sh without ; | & \` > < \$(." ;;
esac
case "$cmd" in
    *"
"*) deny "Multi-line commands are blocked for this subagent." ;;
esac

# Strip leading whitespace and an optional "bash "
t="${cmd#"${cmd%%[![:space:]]*}"}"
t="${t#bash }"
t="${t#"${t%%[![:space:]]*}"}"

case "$t" in
    "$WRAPPER_ABS"|"$WRAPPER_ABS "*) exit 0 ;;
    '~/.claude/agy/agy-run.sh'|'~/.claude/agy/agy-run.sh '*) exit 0 ;;
esac

deny "This subagent may call only ~/.claude/agy/agy-run.sh via Bash. Requested was: ${cmd:0:120}"
