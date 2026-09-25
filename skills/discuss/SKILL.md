---
name: discuss
description: Send a finished spec/design document to an explicitly chosen external engine to challenge whether it should be built at all — advisory, not gating
argument-hint: "<engine> <model> [spec-path] [note] | resume <engine> <model> [spec-path] [note] | reset <spec-path> <engine> | show <spec-path> <engine>"
---

# Discuss

A manually triggered cross-check for a spec/design document, **before** it
becomes an implementation plan. Unlike `external-plan-review` (checks whether a
*plan* is cleanly implementable), this is about the stage before: Is the
underlying problem real at all? Do the assumptions hold? Should this even be
built?

No automatic quota routing as in
`external-ask`/`external-plan-review`/`external-code-review` — engine and model
are **given explicitly** on every call, because this is a deliberate, targeted
action, not a routine choice.

State persists under `~/.claude/skills/external-review/state/`.

## Arguments

- `<engine>` — one of `codex` / `agy` / `opencode` / `commandcode`.
- `<model>` — the model identifier for this engine (e.g. `gpt-5.6-sol`,
  `gpt-6-astra`, `deepseek/deepseek-v4-pro`, `zai-org/GLM-5.3`, ...).
- `[spec-path]` — optional. **If missing, use the spec document last written in
  this conversation or just discussed** (e.g. the file just created via
  `superpowers:brainstorming` under `docs/superpowers/specs/`). Ask only if no
  spec document is recognizable in the current session.
- `[note]` — optional, free text. Anything that is not recognizable as
  `<engine>`/`<model>`/an existing file path counts as a note (e.g. "check in
  particular whether the cache assumption in section 3 is correct").
- `resume ...` — follow-up question/objection on a running challenge of the same
  engine+spec combination.
- `reset <spec-path> <engine>` — delete state, the next call starts fresh.
- `show <spec-path> <engine>` — display the last answer without a new call.

## Execution

1. **Parse `$ARGUMENTS`**: the first recognizable token from `{codex, agy,
   opencode, commandcode}` is `<engine>`, the next token is `<model>`. After
   that: a token that is an existing file path (or ends in `.md`) is
   `[spec-path]` — otherwise derive the spec path from the conversation as
   described above. Everything remaining is the note.

2. **Start** (no state present):
   ```bash
   bash ~/.claude/skills/external-review/engines/<engine>.sh start \
       --prompt-file ~/.claude/skills/external-review/prompts/spec-challenge-start.tpl \
       --target <spec-path> --model <model> [--dir <repo-root>] -- "<note>"
   ```

3. **Resume** (state present, or the user said `resume`):
   ```bash
   bash ~/.claude/skills/external-review/engines/<engine>.sh resume \
       --prompt-file ~/.claude/skills/external-review/prompts/spec-challenge-resume.tpl \
       --target <spec-path> --model <model> [--dir <repo-root>] -- "<note>"
   ```

4. **Reset/Show**: analogous to the other external review skills, with
   `<engine>` explicit instead of automatic selection.

5. **Pass `--dir <repo-root>` (project root) for `agy`, `opencode`,
   `commandcode`** — the engine should be able to check the claims in the spec
   against the real code, not just believe the text. That is the actual purpose
   of this skill. **For `codex` omit `--dir`** — that flag does not exist there
   (`codex.sh` does not know it and would otherwise accidentally mix it into the
   note); Codex gets repo access automatically via the working directory from
   which `codex exec` runs.

6. **On quota exhaustion (exit 3)**: tell the user and ask whether another
   engine/model should be tried or whether to wait — **no** automatic switch as
   in the other external review skills, because engine and model were
   deliberately chosen by the user here.

7. **No verdict tags, no gate**: show the answer verbatim, highlighting the
   **bottom line**. If the answer contradicts your own prior impression, make
   that especially clear to the user — a contradiction is the actual signal this
   skill serves (see `external-ask`).

## When to Use

- The user wants a second, critical opinion before a larger overhaul on whether
  the plan makes sense at all — regardless of whether they can technically judge
  themselves whether a problem suspected by Claude is real.
- After a session in which Claude asserted a bug/a need that cannot be obviously
  verified.

## When NOT to Use

- For the quality/implementability of a finished plan — use
  `external-plan-review` for that.
- For code reviews of a diff — use `external-code-review` for that.
- As a mandatory step for every little thing — this is deliberately a manual
  tool, not an automatic gate in the pipeline.
