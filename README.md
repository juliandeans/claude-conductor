# claude-conductor

My personal [Claude Code](https://docs.claude.com/en/docs/claude-code) workflow:
**Claude plans, delegates and reviews — cheaper models do the typing and give
second opinions.**

> **This is a showcase, not a tool.** It is a snapshot (September 2026) of the
> setup I use every day, cleaned up for reading. It is wired to my accounts,
> CLIs and model names, which change every few weeks — expect to adapt things
> rather than install them. I am not a professional developer; this grew out of
> trying to get real work done without burning through my Claude quota.

## The idea

Claude is the most capable model I have access to, but also the one whose
quota runs out first. So Claude should spend its tokens on what it is best at —
understanding the task, deciding, and checking the result — and hand the rest
to other models:

| Role | Who | Why |
|---|---|---|
| Coordinate, decide, review every diff | Claude (main session) | The only instance whose judgement is trusted |
| Write the code | DeepSeek 4.1 Flash via [Command Code](https://commandcode.ai) (`deepseek-implement`) | Cheap, fast, good enough when the brief is precise |
| Read a lot, summarize a little | Gemini via the Antigravity CLI (`gemini-delegate`) | Large context, separate quota |
| Second opinion on plans and diffs | Codex (GPT), Command Code, Gemini (`external-*` skills) | A different model family finds different mistakes |
| Mechanical work, analysis | Claude Sonnet / Haiku subagents | Never let a subagent silently inherit the expensive model |

Two rules hold the whole thing together:

1. **Claude is the only reviewer that counts.** A delegated model's own
   "done" is not evidence. After every delegated change Claude reads
   `git status`, the full diff and runs the tests itself.
2. **Claude reviewing Claude shares Claude's blind spots.** That is why the
   important reviews go to a model from a different vendor — and why
   *disagreement* from that model is a strong signal, while agreement is a
   weak one.

## How a change flows

`CLAUDE.md` sorts every task into one of three tiers before starting:

- **Trivial** (typo, one-liner) — just do it.
- **Small** (a bounded feature, a bug with a known cause) —
  `deepseek-implement` writes it, Claude reviews the whole diff, a fast
  external model reads it once more. No plan document.
- **Large or risky** (architecture, many files, unclear bugs, migrations,
  deletion, anything irreversible) — brainstorm → written plan → external plan
  review → implementation task by task → external code review → finish the
  branch. The process steps come from the
  [superpowers](https://github.com/obra/superpowers) plugin.

## What's inside

```
CLAUDE.md                  the rulebook (global ~/.claude/CLAUDE.md)
agents/                    gemini-delegate, gemini-precheck (Claude Code subagents)
agy/                       wrapper around the Antigravity (Gemini) CLI + a bash guard
skills/
  deepseek-implement/      delegate implementation to DeepSeek, wrapped in a git-state guard
  external-review/         shared engine layer: codex.sh, commandcode.sh, agy.sh, opencode.sh
                           (OpenCode Go is gone, kept as a reference backend),
                           quota-check.sh, prompt templates
  external-code-review/    iterative diff review until APPROVED
  external-plan-review/    iterative plan review before any code is written
  external-ask/            free-form second opinion, advisory only
  external-usage/          quota overview across all engines
  discuss/                 "should we build this at all?" challenge for a finished spec
  start-session/           read HANDOFF.md + repo state, summarize, wait for direction
  end-session/             nothing may stay only in the chat: triage, update docs, rewrite HANDOFF.md
  postmortem/ solved/ chip/  small helpers (decision log entries, archiving issues, follow-up tasks)
examples/
  commandcode-settings.json  deny list for running a foreign agent with --yolo
```

## Ideas worth stealing

**Delegation with a git-state guard.** `deepseek-implement` runs a foreign
coding agent non-interactively in your repo. Its permission rules are pattern
matches, not a sandbox — so every run is wrapped in a snapshot of HEAD, branch,
stash count, tag count and staged index. If any of that changed, the run fails
with a distinct exit code and Claude stops to investigate instead of trusting
the report.

**One engine interface, many vendors.** Every reviewer backend in
`skills/external-review/engines/` implements the same
`start | resume | reset | show` commands (plus `quota` where the vendor exposes
one; Gemini's quota is read by `quota-check.sh` directly) and writes its report to the
same place. The review skills don't care which vendor answers, and switching
engines never overwrites another engine's session.

**Engine choice by remaining quota.** `quota-check.sh` asks every provider how
much quota is left (costs zero tokens) and writes a priority order. Routine
reviews take the first engine with quota; when one runs dry mid-session, the
skill moves to the next without asking. Premium models are never picked
automatically — the skill asks first.

**Nothing lives only in the chat.** Every piece of information has exactly one
home (`HANDOFF.md` for "where am I", a decision log for "why", `KNOWN-ISSUES.md`
for accepted problems …). `end-session` enforces it; `HANDOFF.md` is
*overwritten*, not appended to, so it stays short enough to actually be read.

**Cheap reading, expensive judging.** Broad reads (big diffs, logs, doc-vs-code
checks) go to Gemini with an explicit file list. Gemini's answer is treated as
an opinion: every finding is checked against the real code before anything
changes.

## Lessons learned

- **Providers disappear.** In September 2026 one of my backends (OpenCode Go)
  vanished overnight and the implementer had to move to Command Code within an
  afternoon. Keep the vendor-specific part thin.
- **Headless agents withhold the shell.** Command Code's print mode refuses
  shell commands unless you run it with `--yolo` — so the safety has to come
  from a deny list in a settings file (see `examples/`) plus the git guard.
- **A subagent's report about its own scope is unreliable.** Diff against the
  list of files you allowed, every time.
- **Say when a check didn't run.** If an external review fails for lack of
  quota, the workflow says so instead of silently skipping it.

## If you want to try it

You will need Claude Code with the superpowers plugin, `jq`, and whichever
CLIs you want to use as engines (`cmd` from Command Code, `codex`, the
Antigravity CLI `agy`, `opencode`). The skills expect to live in
`~/.claude/skills/`, the agents in `~/.claude/agents/`, the Gemini wrapper in
`~/.claude/agy/`. `<config-repo>` in a few places stands for wherever you keep
your config under version control.

Some files point to `docs/provider-quota-management.md`, a longer design
document of my private setup that is not included here. The review prompts also
mention TRIP, a checklist system from my private setup; they skip it when it is
absent. The German origin
still shows in a few values that scripts parse or that are part of a CLI, so
they were left unchanged: quota tiers `hoch` / `normal` / `gedrosselt`, the
Gemini run classes `--class breite` (broad reading) and `--class gegencheck`
(independent cross-check), and the findings schema `befunde` with severities
`hoch` / `mittel` / `niedrig`.

## License

[MIT](LICENSE)
