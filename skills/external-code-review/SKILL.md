---
name: external-code-review
description: Iterative code review via external engine (Codex, OpenCode-Go, Antigravity, or CommandCode)
argument-hint: "<target> [extra context] | reset <target> | show <target>"
---

# External Code Review

Iterative code review via an external engine on uncommitted changes. The engine reads the plan and runs `git status -s` / `git diff HEAD` to inspect the change set.

State persisted under `~/.claude/skills/external-review/state/`.

## Arguments

- `<target>` — auto: start if no state, resume if exists. Usually a plan path or a free-form label.
- `reset <target>` — drop state, next call starts fresh.
- `show <target>` — display latest review without calling an engine.

## Execution

1. **Parse `$ARGUMENTS`**: extract action and target.

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
     question, architecture-relevant diff) — **briefly ask** which premium
     model should be used (`gpt-5.6-sol` / `gpt-6-astra` / `deepseek-v4-pro` /
     CommandCode `deepseek/deepseek-v4-pro` or `zai-org/GLM-5.3`), see
     `external-plan-review/SKILL.md` for the exact wording. Never switch to a
     premium model on your own, not even with an obvious benefit — the user
     decides that.
   - If the quota of the engine requested for this is insufficient
     (`gedrosselt`): say that right away, e.g. "Codex has only X% weekly quota
     left — is that enough for Sol here, or would you rather use another
     engine/wait?", and leave the decision to the user.
   - Antigravity: `--model` stays ignored, `agy-run.sh` chooses Flash/Pro
     itself via the `--class` classification.

3. **Auto** — try `start` first (exit code 2 → `resume`):
   - **Start**: `bash ~/.claude/skills/external-review/engines/<engine>.sh start --prompt-file ~/.claude/skills/external-review/prompts/code-review-start.tpl --target <target> [--dir <repo-root>] [extra]`
   - **Resume**: `bash ~/.claude/skills/external-review/engines/<engine>.sh resume --prompt-file ~/.claude/skills/external-review/prompts/code-review-resume.tpl --target <target> [--dir <repo-root>] [--notes "<implementer notes>"] [extra]`

4. **Synthesize** (after convergence): `bash ~/.claude/skills/external-review/engines/<engine>.sh start --prompt-file ~/.claude/skills/external-review/prompts/code-review-synthesize.tpl --target <target>-synthesis [--dir <repo-root>]`

5. **Reset/Show**: same pattern as plan-review.

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
   are not separated by this — keep using different `--target` labels for that.

7. **Parse trailing tag**: same as plan-review (APPROVED / REQUEST_CHANGES / NEEDS_REWORK).

## Engine-specific notes

Same as `external-plan-review`.

## Loop Shape

```
turn 1: start -> REQUEST_CHANGES (Critical: A, Major: B C)
         address A B C
turn 2: resume -> REQUEST_CHANGES (A B addressed, Minor: C partial)
         address C
turn 3: resume -> APPROVED -> synthesize for archival
```
