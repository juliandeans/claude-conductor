---
name: external-usage
description: Show quota status for all external review engines (Codex, OpenCode-Go, Antigravity, CommandCode)
argument-hint: ""
---

# External Engine Usage

Show the current quota status for all external review engines.

## Execution

1. **Codex quota** (costs 0 tokens, direct REST call against
   `chatgpt.com/backend-api/wham/usage` with the token from
   `~/.codex/auth.json`):
   ```bash
   bash ~/.claude/skills/external-review/engines/codex.sh quota
   ```
   Returns JSON with `used_pct_primary` (5h window), `used_pct_secondary`
   (weekly window), `resets_at_secondary` (Unix timestamp),
   `reset_credits_available` (+ expiry via `reset_credit_expires_at`, fetched
   via `codex_quota_probe.py`), `plan_type`, `credit_balance`,
   `spend_control_reached`.

2. **Antigravity/Gemini quota** (costs 0 tokens, `/usage` is a client-side
   intercepted command, never reaches the model):
   ```bash
   agy -p "/usage" --output-format json
   ```
   Returns structured buckets for two groups (Gemini models; Claude/GPT models
   via Antigravity), each with a weekly and 5-hour window
   (`remaining_fraction`, `reset_time`).

3. **OpenCode-Go** (no cost proxy anymore, a real percentage endpoint):
   ```bash
   bash ~/.claude/skills/external-review/engines/opencode.sh quota
   ```
   Returns `weekly_pct`/`rolling_pct`/`monthly_pct` (+ `status` field per
   window) from `opencode.ai/zen/go/v1/usage`, token from
   `~/.local/share/opencode/auth.json`.

4. **CommandCode quota** (costs 0 tokens, undocumented alpha billing
   endpoint — see `docs/provider-quota-management.md`):
   ```bash
   bash ~/.claude/skills/external-review/engines/commandcode.sh quota
   ```
   Returns `weekly_used`/`weekly_cap`, `five_hour_used`/`five_hour_cap`
   (+ `exceeded` flags), `monthly_credits`. If `~/.commandcode/auth.json`
   is missing (no `cmd login` run) or the query fails → not available.

5. **Present a table** to the user with all engines, their available models, quota status, and reset times.

Example output format:
```
Engine          Model               Quota               Reset
────────────────────────────────────────────────────────────
Antigravity     gemini-3.8-flash    92%                 01.09. 20:54
Codex           gpt-5.6-sol         71% (week)          07.09. 12:55
Codex           gpt-5.6-luna        71% (week)          07.09. 12:55
OpenCode-Go     deepseek-v4.1-flash   98% (week)         07.09.
OpenCode-Go     deepseek-v4-pro     98% (week)          07.09.
CommandCode     mimo-v2.5-pro       96% (week)          08.09. 13:27
CommandCode     glm-5.3-flash       96% (week)          08.09. 13:27
CommandCode     deepseek-v4-pro     96% (week)          08.09. 13:27
CommandCode     GLM-5.3 (Oracle)    96% (week)          08.09. 13:27

Automatic priority order of this session: see
~/.claude/skills/external-review/state/usage-priority.json
```

6. **No action** — this skill is purely informational.
