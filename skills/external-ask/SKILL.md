---
name: external-ask
description: Ask an external engine for a grounded second opinion - advisory, not gating
argument-hint: "<topic-label> <question> | reset <topic-label> | show <topic-label>"
---

# External Ask

Free-form second opinion from an external engine on any matter. Advisory, not authoritative — no verdict tags, nothing is gated on the answer.

State persisted per topic label under `~/.claude/skills/external-review/state/`.

## Arguments

- `<topic-label> <question>` — auto: start if no state, follow up if exists.
- `reset <topic-label>` — drop state.
- `show <topic-label>` — display latest answer.

## Execution

1. **Parse `$ARGUMENTS`**: extract action, topic label, and question.

2. **Choose the engine automatically** — before each selection run
   `bash ~/.claude/skills/external-review/engines/quota-check.sh` once
   (costs 0 tokens, takes only a few seconds — no cache, always fresh),
   then read `~/.claude/skills/external-review/state/usage-priority.json`.
   - Choose the first engine from `priority_order` whose entry has
     `available: true` and which has not yet been marked as exhausted in this
     session (see point 6 below). If all entries are `available: false` or
     exhausted, tell the user instead of trying an unusable engine.
   - Model choice **within** the chosen engine: the respective
     `default_model` for routine questions, without asking. If the question
     is especially important/architecture-relevant or an Oracle-like final
     check at the end of a larger revision — **briefly ask** which premium
     model should be used (`gpt-5.6-sol` / `gpt-6-astra` / `deepseek-v4-pro` /
     CommandCode `deepseek/deepseek-v4-pro` or `zai-org/GLM-5.3`, see
     `external-plan-review/SKILL.md`, Engine-specific notes). Never switch to
     a premium model on your own, not even with an obvious benefit — the user
     decides that.
   - If the quota of the engine requested for this is insufficient
     (`gedrosselt`): say that right away, e.g. "Codex has only X% weekly quota
     left — is that enough for Sol here, or would you rather use another
     engine/wait?", and leave the decision to the user.
   - Antigravity: `--model` stays ignored, `agy-run.sh` chooses Flash/Pro
     itself via the `--class` classification.

3. **Start**:
   ```bash
   bash ~/.claude/skills/external-review/engines/<engine>.sh start \
       --prompt-file ~/.claude/skills/external-review/prompts/ask-start.tpl \
       --target <topic-label> [--dir <repo-root>] -- "<question>"
   ```

4. **Follow up** (session exists):
   ```bash
   bash ~/.claude/skills/external-review/engines/<engine>.sh resume \
       --prompt-file ~/.claude/skills/external-review/prompts/ask-followup.tpl \
       --target <topic-label> [--dir <repo-root>] -- "<follow-up>"
   ```

5. **Reset/Show**: same pattern.

6. **On exit 3** (quota exhausted): mark the affected engine as exhausted for
   the rest of this session (only in your own context, no file) and
   automatically switch to the next engine from `priority_order`, without
   asking. If all three are exhausted, tell the user.

   **Note:** `thread_file`/`review_file`/`events_file` (from `_common.sh`)
   are separate per `<target>` **and** engine (the engine name comes from the
   filename of the calling script, e.g. `codex.sh` → `codex`). An engine
   switch therefore no longer overwrites someone else's session — simply
   call `start` with the new engine, the old thread is preserved for a later
   `resume`. Two **models of the same** engine in parallel for the same topic
   are not separated by this — keep using different `<topic-label>`s for that.

7. **No verdict parsing** — surface the answer verbatim. Disagreement with your position is a strong signal worth surfacing to the user.

## When to use

- Second opinion on architecture/design decisions.
- Root-cause help when stuck on a bug.
- "Red-team this conclusion" before presenting to the user.

## When NOT to use

- Questions needing user preference — ask the user, not an engine.
- Trivial lookups — every ask costs a run.
- As a gate — use plan-review or code-review for that.
