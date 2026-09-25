---
name: external-plan-review
description: Iterative plan review via external engine (Codex, OpenCode-Go, Antigravity, or CommandCode)
argument-hint: "<plan-path> [extra context] | reset <plan-path> | show <plan-path>"
---

# External Plan Review

Iterative review of a planning document via an external engine. The engine is chosen automatically from quota priority on each call.

State persisted under `~/.claude/skills/external-review/state/`.

## Arguments

- `<plan-path>` — auto: start if no state, resume if exists. Trailing text is extra context.
- `reset <plan-path>` — drop state, next call starts fresh.
- `show <plan-path>` — display latest review without calling an engine.

## Execution

1. **Parse `$ARGUMENTS`**: extract action (`reset`/`show`/auto) and plan path.

2. **Choose the engine automatically** — before each selection run
   `bash ~/.claude/skills/external-review/engines/quota-check.sh` once
   (costs 0 tokens, takes only a few seconds — no cache, always fresh),
   then read `~/.claude/skills/external-review/state/usage-priority.json`.
   - Choose the first engine from `priority_order` whose entry has
     `available: true` and which has not yet been marked as exhausted in this
     session (see point 6 below). If all entries are `available: false` or
     exhausted, tell the user instead of trying an unusable engine.
   - Model choice **within** the chosen engine: the respective
     `default_model` for routine turns, without asking. If the task is
     premium-worthy (final review after a larger overhaul, Oracle-like
     question, architecture-relevant plan) — **briefly ask** which premium
     model should be used (`gpt-5.6-sol` / `gpt-6-astra` / `deepseek-v4-pro` /
     CommandCode `deepseek/deepseek-v4-pro` or `zai-org/GLM-5.3`), e.g. "This
     plan review is important enough for a premium model — Sol, Astra,
     DeepSeek-Pro or GLM-5.3?". Never switch to a premium model on your own,
     not even with an obvious benefit — the user decides that, not the
     assessment "benefits from it".
   - If the quota of the engine requested for this is insufficient
     (`gedrosselt`): say that right away, e.g. "Codex has only X% weekly quota
     left — is that enough for Sol here, or would you rather use another
     engine/wait?", and leave the decision to the user.
   - Antigravity: `--model` stays ignored, `agy-run.sh` chooses Flash/Pro
     itself via the `--class` classification.

3. **Auto** — try `start` first (exit code 2 = session exists → use `resume`):
   - **Start**: `bash ~/.claude/skills/external-review/engines/<engine>.sh start --prompt-file ~/.claude/skills/external-review/prompts/plan-review-start.tpl --target <plan-path> [--dir <repo-root>] [extra]`
   - **Resume**: `bash ~/.claude/skills/external-review/engines/<engine>.sh resume --prompt-file ~/.claude/skills/external-review/prompts/plan-review-resume.tpl --target <plan-path> [--dir <repo-root>] [--notes "<implementer notes>"] [extra]`

4. **Reset**: `bash ~/.claude/skills/external-review/engines/<engine>.sh reset --target <plan-path>`

5. **Show**: `bash ~/.claude/skills/external-review/engines/<engine>.sh show --target <plan-path>`

6. **On exit 3** (quota exhausted): mark the affected engine as exhausted for
   the rest of this session (only in your own context, no file) and
   automatically switch to the next engine from `priority_order`, without
   asking. If all three are exhausted, tell the user.

   **Note:** `thread_file`/`review_file`/`events_file` (from `_common.sh`)
   are separate per `<target>` **and** engine (the engine name comes from the
   filename of the calling script, e.g. `codex.sh` → `codex`). An engine
   switch therefore no longer overwrites someone else's session — simply
   call `start` with the new engine, the old thread is preserved for a later
   `resume`. Two **models of the same** engine in parallel for the same target
   (e.g. CommandCode once with `xiaomi/mimo-v2.5-pro`, once with
   `z-ai/glm-5.3-flash`) are not separated by this — keep using different
   `--target` labels for that (e.g. `<target>-mimo`, `<target>-glmflash`).

7. **Parse trailing tag**:
   - `APPROVED` — tell user, done.
   - `REQUEST_CHANGES` — engage critically: fix legitimate findings by editing the plan, push back on incorrect ones. Surface review verbatim, propose fixes, let user confirm.
   - `NEEDS_REWORK` — surface to user before mass-editing.

## Engine-specific notes

- **Codex**: `--model` defaults to gpt-5.6-luna (script default, routine
  turns, xhigh reasoning effort). Pass `--model gpt-5.6-sol` (xhigh effort)
  or `--model gpt-6-astra` (medium effort — `codex.sh` sets this per-model
  default automatically) only after the user has confirmed it per the
  "Modellwahl" rule above — never automatically.
- **OpenCode-Go**: `--model` must include the `opencode-go/` prefix (e.g., `opencode-go/deepseek-v4.1-flash`). Pass `--dir <repo-root>`.
- **Antigravity**: `--model` is ignored (agy-run.sh selects based on quota). Pass `--dir` with the relevant source directories.
- **CommandCode**: `--model` needs the full provider prefix. `default_model`
  from `usage-priority.json` is the default choice for fast, non-critical turns
  and small findings — switches automatically by time of day (Europe/Berlin)
  between `xiaomi/mimo-v2.5-pro` (Mon-Fri 03-06 and 08-12 o'clock) and
  `deepseek/deepseek-v4.1-flash` (otherwise, incl. Sat/Sun); see
  `docs/provider-quota-management.md` for details. `z-ai/glm-5.3-flash`
  is a further Flash tier — selectable when the user deliberately wants a
  second, different opinion alongside `default_model` (e.g. "have Gemini and
  GLM-5.3-Flash review once each"); use different `--target` labels for that,
  see above. For an Oracle-like final check at the end of a larger revision
  (typically via `external-ask`), use `zai-org/GLM-5.3` instead of
  `deepseek/deepseek-v4-pro` — only after asking the user (see model choice
  above); both are premium tiers of the same quota, no separate gating. No
  real session resume (see `commandcode.sh`): `resume` runs as a new,
  stateless call with the previous review in the prompt. Outside the
  expensive hours, CommandCode (Flash 4.1) together with Gemini is the
  recommended combination when the user deliberately wants a second opinion.

## Loop Shape

```
turn 1: start -> REQUEST_CHANGES (A B C)
         address A B C
turn 2: resume -> REQUEST_CHANGES (A B addressed, C stale, new D)
         address C D
turn 3: resume -> APPROVED
```
