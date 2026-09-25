#!/usr/bin/env bash
# Collects quota levels from Codex, Antigravity/Gemini, OpenCode-Go and
# CommandCode, applies the priority rules (see the provider quota design notes,
# not included in this repo) and writes state/usage-priority.json (snapshot, overwritten)
# + state/usage-history.jsonl (history, appended -- JSON Lines: one
# complete snapshot per line, exactly the same schema as
# usage-priority.json; see docs/provider-quota-management.md for the
# format, intended to be read by a dashboard).
# Usage: quota-check.sh
# Emits one line of plain-text summary to stdout.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# ════════════════════════════════════════════════════════════════════════
# CURRENT DEAL PREFERENCES — maintained by hand, changes all the time.
# Providers occasionally have limited-time discounts on individual models.
# Enter here what should currently be preferred — Claude sees this on every
# session (status line + usage-priority.json), even without anyone looking
# specially.
#
# CURRENT_DEALS_NOTE: free text, what is currently cheap/preferred. Leave
#   empty ("") = no active hint.
# COMMANDCODE_DEFAULT_OVERRIDE: replaces CommandCode's default_model
#   mechanically, including the time rule further below. Leave empty ("") =
#   normal, time-dependent choice.
# ════════════════════════════════════════════════════════════════════════
CURRENT_DEALS_NOTE=""
COMMANDCODE_DEFAULT_OVERRIDE=""
# ════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════
# COMMANDCODE PEAK HOURS — DeepSeek Flash 4.1 is twice as expensive at
# CommandCode at certain times (local time, Europe/Berlin):
# Mon-Fri 03:00-06:00 and 08:00-12:00 (06:00/12:00 themselves already count
# as the cheap time). In these windows Mimo Pro stays the default, otherwise
# (also all day Sat/Sun) Flash 4.1 is the cheaper and meanwhile
# very good default choice. COMMANDCODE_DEFAULT_OVERRIDE (above) always
# takes precedence over this rule.
# ════════════════════════════════════════════════════════════════════════
COMMANDCODE_PEAK_DOW="$(TZ=Europe/Berlin date +%u)"          # 1=Mon .. 7=Sun
COMMANDCODE_PEAK_HOUR="$((10#$(TZ=Europe/Berlin date +%H)))" # base 10 because of a leading zero (08, 09)
COMMANDCODE_IS_PEAK=false
if [ "$COMMANDCODE_PEAK_DOW" -le 5 ]; then
  if { [ "$COMMANDCODE_PEAK_HOUR" -ge 3 ] && [ "$COMMANDCODE_PEAK_HOUR" -lt 6 ]; } || { [ "$COMMANDCODE_PEAK_HOUR" -ge 8 ] && [ "$COMMANDCODE_PEAK_HOUR" -lt 12 ]; }; then
    COMMANDCODE_IS_PEAK=true
  fi
fi
# ════════════════════════════════════════════════════════════════════════

HISTORY_FILE="$STATE_DIR/usage-history.jsonl"
PRIORITY_FILE="$STATE_DIR/usage-priority.json"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Antigravity / Gemini ---
# Direct `agy -p "/usage" --output-format json` call instead of text scraping
# from `agy-run.sh --dry-run` -- structured data (0 tokens, /usage is a
# client-side intercepted command, never reaches the model) instead of regex on
# rendered text. Additionally returns separate weekly AND 5h windows,
# as well as the separate "Claude and GPT models" pool (Sonnet/Opus/GPT-OSS via
# Antigravity) -- previously only a single aggregated Gemini percentage.
AGY_JSON="$(agy -p "/usage" --output-format json 2>/dev/null || true)"
if ! printf '%s' "$AGY_JSON" | jq -e '.command.data.groups | length > 0' >/dev/null 2>&1; then
  # agy not found/failed -- not a "low quota", the
  # probe itself delivered no data. Treat it just like a
  # missing Codex/OpenCode CLI: not available, do not falsely
  # prefer it.
  AGY_TIER_JSON='{"available":false,"remaining_pct":0,"five_hour_used_pct":0,"resets_at":null,"five_hour_resets_at":null,"thirdparty_weekly_remaining_pct":null,"thirdparty_five_hour_remaining_pct":null,"tier":"gedrosselt"}'
else
  AGY_TIER_JSON="$(printf '%s' "$AGY_JSON" | jq -c '
        (.command.data.groups[] | select(.name == "Gemini Models") | .buckets) as $gbuckets
        | ($gbuckets[] | select(.id == "gemini-weekly")) as $gw
        | ($gbuckets[] | select(.id == "gemini-5h")) as $g5
        | ((.command.data.groups[] | select(.name == "Claude and GPT models") | .buckets) // []) as $tbuckets
        | (($tbuckets[]? | select(.id == "3p-weekly")).remaining_fraction) as $tw
        | (($tbuckets[]? | select(.id == "3p-5h")).remaining_fraction) as $t5
        | ($gw.remaining_fraction * 100) as $remaining_pct
        | {
            available: true,
            remaining_pct: $remaining_pct,
            five_hour_used_pct: ((1 - $g5.remaining_fraction) * 100),
            resets_at: $gw.reset_time,
            five_hour_resets_at: $g5.reset_time,
            thirdparty_weekly_remaining_pct: (if $tw then ($tw * 100) else null end),
            thirdparty_five_hour_remaining_pct: (if $t5 then ($t5 * 100) else null end),
            tier: (if $remaining_pct >= 70 then "hoch" elif $remaining_pct >= 40 then "normal" else "gedrosselt" end)
          }
    ')"
fi
GEMINI_AVAILABLE="$(printf '%s' "$AGY_TIER_JSON" | jq -r '.available')"
GEMINI_PCT="$(printf '%s' "$AGY_TIER_JSON" | jq -r '.remaining_pct | floor')"
GEMINI_TIER="$(printf '%s' "$AGY_TIER_JSON" | jq -r '.tier')"

# --- Codex ---
# NEVER treat an empty/failed probe (e.g. `codex` CLI not installed)
# as "full quota" -- otherwise an unusable engine ends up
# first in the priority. Instead explicitly "gedrosselt" +
# available:false, so the review skills skip it.
CODEX_JSON="$(bash "$SCRIPT_DIR/codex.sh" quota 2>/dev/null || echo '{}')"
# Check required fields instead of merely comparing against "{}" -- an
# incomplete/broken answer (missing fields) should count as
# "not available" just like a completely empty one.
if ! printf '%s' "$CODEX_JSON" | jq -e 'has("used_pct_secondary") and has("resets_at_secondary")' >/dev/null 2>&1; then
  CODEX_TIER_JSON='{"available":false,"weekly_remaining_pct":0,"primary_used_pct":0,"reset_credit_available":false,"reset_credit_expires_at":null,"reset_credit_expiring_soon":false,"resets_at":null,"plan_type":null,"credit_balance":null,"spend_control_reached":false,"default_model":"gpt-5.6-luna","premium_model":"gpt-5.6-sol","tier":"gedrosselt"}'
else
  CODEX_TIER_JSON="$(printf '%s' "$CODEX_JSON" | jq -c --argjson now "$(date -u +%s)" '
        (.used_pct_secondary // 0) as $used_sec
        | (100 - $used_sec) as $remaining_weekly
        | (.resets_at_secondary // $now) as $resets_at
        | (($resets_at - $now) / 86400) as $days_to_reset
        | (.reset_credits_available // 0) as $credits
        | (.used_pct_primary // 0) as $primary_used
        | (.reset_credit_expires_at // null) as $credit_expires_at
        | (if $credit_expires_at then (($credit_expires_at - $now) / 86400) else null end) as $credit_days_left
        | (.spend_control_reached // false) as $spend_reached
        | {
            available: true,
            weekly_remaining_pct: $remaining_weekly,
            primary_used_pct: $primary_used,
            reset_credit_available: ($credits > 0),
            reset_credit_expires_at: $credit_expires_at,
            reset_credit_expiring_soon: (($credits > 0) and ($credit_days_left != null) and ($credit_days_left < 14)),
            resets_at: $resets_at,
            plan_type: .plan_type,
            credit_balance: (.credit_balance // null),
            spend_control_reached: $spend_reached,
            default_model: "gpt-5.6-luna",
            premium_model: "gpt-5.6-sol",
            tier: (
                if $spend_reached then "gedrosselt"
                elif $credits > 0 then "hoch"
                elif $primary_used > 80 then "gedrosselt"
                elif $remaining_weekly > 50 then "hoch"
                elif $days_to_reset <= 2 then "hoch"
                else "gedrosselt"
                end
            )
          }
    ')"
fi

# --- OpenCode-Go ---
# Real percentage endpoint (opencode.sh quota) instead of the earlier cost
# approximation -- weekly_remaining_pct as with the other three engines.
# Every status field != "ok" (a server-side signal) always takes precedence over
# the percentage calculation, similar to the exceeded flag at CommandCode.
OPENCODE_JSON="$(bash "$SCRIPT_DIR/opencode.sh" quota 2>/dev/null || echo '{}')"
if ! printf '%s' "$OPENCODE_JSON" | jq -e 'has("weekly_pct")' >/dev/null 2>&1; then
  OPENCODE_TIER_JSON='{"available":false,"weekly_remaining_pct":0,"rolling_used_pct":0,"monthly_used_pct":0,"resets_at":null,"default_model":"opencode-go/glm-5.3-flash","premium_model":"opencode-go/deepseek-v4.1-flash","tier":"gedrosselt"}'
else
  OPENCODE_TIER_JSON="$(printf '%s' "$OPENCODE_JSON" | jq -c '
        (100 - (.weekly_pct // 0)) as $remaining_weekly
        | (([.rolling_status, .weekly_status, .monthly_status] | map(select(. != null and . != "ok")) | length) > 0) as $status_issue
        | {
            available: true,
            weekly_remaining_pct: $remaining_weekly,
            rolling_used_pct: (.rolling_pct // 0),
            monthly_used_pct: (.monthly_pct // 0),
            resets_at: .weekly_resets_at,
            default_model: "opencode-go/glm-5.3-flash",
            premium_model: "opencode-go/deepseek-v4.1-flash",
            tier: (
                if $status_issue then "gedrosselt"
                elif $remaining_weekly > 50 then "hoch"
                elif $remaining_weekly > 20 then "normal"
                else "gedrosselt"
                end
            )
          }
    ')"
fi

# --- CommandCode ---
# Undocumented alpha billing endpoint (see commandcode.sh) -- returns
# real percentages, just like the other three engines. Can change
# at any time without warning (not officially documented) -- therefore,
# as everywhere: missing/unrecognized answer -> available:false, never full
# quota. The exceeded flag (server explicitly says "limit exceeded")
# always takes precedence over the percentage calculation.
#
# Besides default_model/premium_model, "z-ai/glm-5.3-flash" is additionally
# selectable at CommandCode -- a further Flash tier (not the
# Oracle premium model "zai-org/GLM-5.3"), intended for a deliberately
# different second opinion alongside default_model, see external-plan-review/
# SKILL.md.
COMMANDCODE_JSON="$(bash "$SCRIPT_DIR/commandcode.sh" quota 2>/dev/null || echo '{}')"
if [ -n "$COMMANDCODE_DEFAULT_OVERRIDE" ]; then
  COMMANDCODE_DEFAULT="$COMMANDCODE_DEFAULT_OVERRIDE"
elif [ "$COMMANDCODE_IS_PEAK" = true ]; then
  COMMANDCODE_DEFAULT="xiaomi/mimo-v2.5-pro"
else
  COMMANDCODE_DEFAULT="deepseek/deepseek-v4.1-flash"
fi
if ! printf '%s' "$COMMANDCODE_JSON" | jq -e '(.weekly_cap // 0) > 0 and (.weekly_used != null)' >/dev/null 2>&1; then
  COMMANDCODE_TIER_JSON="$(jq -nc --arg m "$COMMANDCODE_DEFAULT" \
    '{available:false, weekly_remaining_pct:0, five_hour_used_pct:0, resets_at:null, default_model:$m, premium_model:"deepseek/deepseek-v4-pro", tier:"gedrosselt"}')"
else
  COMMANDCODE_TIER_JSON="$(printf '%s' "$COMMANDCODE_JSON" | jq -c --arg m "$COMMANDCODE_DEFAULT" '
        (100 - (.weekly_used / .weekly_cap * 100)) as $remaining_weekly
        | (if .five_hour_cap > 0 then (.five_hour_used / .five_hour_cap * 100) else 0 end) as $five_hour_pct
        | ((.weekly_exceeded // false) or (.five_hour_exceeded // false) or (.below_threshold // false)) as $exceeded
        | {
            available: true,
            weekly_remaining_pct: $remaining_weekly,
            five_hour_used_pct: $five_hour_pct,
            resets_at: .weekly_resets_at,
            default_model: $m,
            premium_model: "deepseek/deepseek-v4-pro",
            tier: (
                if $exceeded then "gedrosselt"
                elif $remaining_weekly > 50 then "hoch"
                elif $remaining_weekly > 20 then "normal"
                else "gedrosselt"
                end
            )
          }
    ')"
fi

# --- Priority order: tier first (hoch < normal < gedrosselt as
#     rank), on a tie Antigravity/agy before Codex before OpenCode before
#     CommandCode -- except in CommandCode's cheap time (see
#     COMMANDCODE_IS_PEAK above): then CommandCode moves up on a tie to
#     the FIRST spot, because Flash 4.1 is then cheap AND very good. In
#     the expensive time CommandCode stays last in the tie-break
#     order, because the quota source (undocumented alpha
#     endpoint, see commandcode.sh) is the least stable. ---
tier_rank() { case "$1" in hoch) echo 0 ;; normal) echo 1 ;; *) echo 2 ;; esac }
CODEX_TIER="$(printf '%s' "$CODEX_TIER_JSON" | jq -r '.tier')"
OPENCODE_TIER="$(printf '%s' "$OPENCODE_TIER_JSON" | jq -r '.tier')"
COMMANDCODE_TIER="$(printf '%s' "$COMMANDCODE_TIER_JSON" | jq -r '.tier')"

COMMANDCODE_PREF=3
[ "$COMMANDCODE_IS_PEAK" = false ] && COMMANDCODE_PREF=-1

PRIORITY_ORDER="$(jq -nc \
  --argjson gr "$(tier_rank "$GEMINI_TIER")" \
  --argjson cr "$(tier_rank "$CODEX_TIER")" \
  --argjson or_ "$(tier_rank "$OPENCODE_TIER")" \
  --argjson ccr "$(tier_rank "$COMMANDCODE_TIER")" \
  --argjson ccpref "$COMMANDCODE_PREF" \
  '[{name:"agy", rank:$gr, pref:0}, {name:"codex", rank:$cr, pref:1}, {name:"opencode", rank:$or_, pref:2}, {name:"commandcode", rank:$ccr, pref:$ccpref}]
     | sort_by(.rank, .pref) | map(.name)')"

# --- usage-priority.json (snapshot) + usage-history.jsonl (history) ---
# One shared JSON object for both: usage-priority.json is overwritten on every
# check, the same line is additionally appended to usage-history.jsonl.
# Previously the history had its own, incomplete schema
# (only a fraction of the fields per engine, inconsistently named) -- that drifted
# apart with every extension of the tier logic in this session. A
# dashboard that reads state/usage-history.jsonl line by line thus gets
# exactly the same structure per line as usage-priority.json: four engines
# complete (tier, remaining_pct, resets_at, default_model, premium_model, ...),
# not just a single field -- no special case per engine needed.
#
# ⚠️  PITFALL: if you change a field up here (or in one of the four
# ..._TIER_JSON blocks) -- new, renamed, removed -- update
# docs/provider-quota-management.md IN THE SAME STEP, section
# "Verlauf fuer ein Dashboard" (field reference table + example line).
# The user's dashboard reads exactly this schema; documentation that lags behind
# makes the table there wrong, not just incomplete. Do not defer it to "catch up
# later" -- that has already gone wrong several times at exactly this spot.
PRIORITY_JSON="$(jq -nc \
  --arg checked_at "$NOW_ISO" \
  --argjson agy "$AGY_TIER_JSON" \
  --argjson codex "$CODEX_TIER_JSON" \
  --argjson opencode "$OPENCODE_TIER_JSON" \
  --argjson commandcode "$COMMANDCODE_TIER_JSON" \
  --argjson priority_order "$PRIORITY_ORDER" \
  --arg deals_note "$CURRENT_DEALS_NOTE" \
  '{checked_at: $checked_at, agy: $agy, codex: $codex, opencode: $opencode, commandcode: $commandcode, priority_order: $priority_order, current_deals_note: $deals_note}')"

printf '%s\n' "$PRIORITY_JSON" >"$PRIORITY_FILE"
printf '%s\n' "$PRIORITY_JSON" >>"$HISTORY_FILE"

# --- Plain-text summary ---
CODEX_AVAILABLE="$(printf '%s' "$CODEX_TIER_JSON" | jq -r '.available')"
if [ "$CODEX_AVAILABLE" = "false" ]; then
  CODEX_LABEL="unavailable"
else
  CODEX_WEEKLY="$(printf '%s' "$CODEX_TIER_JSON" | jq -r '.weekly_remaining_pct')"
  CODEX_RESETS_EPOCH="$(printf '%s' "$CODEX_TIER_JSON" | jq -r '.resets_at')"
  CODEX_RESETS_H="$(date -r "$CODEX_RESETS_EPOCH" '+%d.%m. %H:%M' 2>/dev/null || echo '?')"
  CODEX_LABEL="${CODEX_WEEKLY}%/week (${CODEX_TIER}, Reset ${CODEX_RESETS_H})"
fi

if [ "$GEMINI_AVAILABLE" = "false" ]; then
  GEMINI_LABEL="unavailable"
else
  GEMINI_LABEL="${GEMINI_PCT}% (${GEMINI_TIER})"
fi

OPENCODE_AVAILABLE="$(printf '%s' "$OPENCODE_TIER_JSON" | jq -r '.available')"
if [ "$OPENCODE_AVAILABLE" = "false" ]; then
  OPENCODE_LABEL="unavailable"
else
  OPENCODE_WEEKLY="$(printf '%s' "$OPENCODE_TIER_JSON" | jq -r '.weekly_remaining_pct | floor')"
  # resets_at here is an ISO-8601 string (no epoch seconds from the API) --
  # show only the date, no timezone conversion needed for the purpose.
  OPENCODE_RESETS_ISO="$(printf '%s' "$OPENCODE_TIER_JSON" | jq -r '.resets_at')"
  OPENCODE_RESETS_H="$(printf '%s' "$OPENCODE_RESETS_ISO" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2}).*/\3.\2./' 2>/dev/null || echo '?')"
  OPENCODE_LABEL="${OPENCODE_WEEKLY}%/week (${OPENCODE_TIER}, Reset ${OPENCODE_RESETS_H})"
fi

COMMANDCODE_AVAILABLE="$(printf '%s' "$COMMANDCODE_TIER_JSON" | jq -r '.available')"
if [ "$COMMANDCODE_AVAILABLE" = "false" ]; then
  COMMANDCODE_LABEL="not logged in (cmd login)"
else
  COMMANDCODE_WEEKLY="$(printf '%s' "$COMMANDCODE_TIER_JSON" | jq -r '.weekly_remaining_pct | floor')"
  COMMANDCODE_RESETS_EPOCH="$(printf '%s' "$COMMANDCODE_TIER_JSON" | jq -r '.resets_at')"
  COMMANDCODE_RESETS_H="$(date -r "$COMMANDCODE_RESETS_EPOCH" '+%d.%m. %H:%M' 2>/dev/null || echo '?')"
  COMMANDCODE_LABEL="${COMMANDCODE_WEEKLY}%/week (${COMMANDCODE_TIER}, Reset ${COMMANDCODE_RESETS_H})"
fi

echo "Codex ${CODEX_LABEL} · Gemini ${GEMINI_LABEL} · OpenCode ${OPENCODE_LABEL} · CommandCode ${COMMANDCODE_LABEL}"

if [ -z "$COMMANDCODE_DEFAULT_OVERRIDE" ]; then
  if [ "$COMMANDCODE_IS_PEAK" = true ]; then
    echo "🕒 CommandCode: peak hours -- Mimo Pro is the default (Flash 4.1 costs double right now)."
  else
    echo "🕒 CommandCode: off-peak -- Flash 4.1 is the default."
  fi
fi

# --- Codex reset-credit warning: does it expire in < 14 days? ---
CODEX_CREDIT_WARN="$(printf '%s' "$CODEX_TIER_JSON" | jq -r '.reset_credit_expiring_soon // false')"
if [ "$CODEX_CREDIT_WARN" = "true" ]; then
  CODEX_CREDIT_EXP_EPOCH="$(printf '%s' "$CODEX_TIER_JSON" | jq -r '.reset_credit_expires_at')"
  CODEX_CREDIT_EXP_H="$(date -r "$CODEX_CREDIT_EXP_EPOCH" '+%d.%m.' 2>/dev/null || echo '?')"
  echo "⚠️  Codex bonus credits expire on ${CODEX_CREDIT_EXP_H} (< 2 weeks) — use them before they lapse."
fi

# --- Deal hint (see CURRENT_DEALS_NOTE above) ---
if [ -n "$CURRENT_DEALS_NOTE" ]; then
  echo "💡 ${CURRENT_DEALS_NOTE}"
fi
