---
name: start-session
description: Begin a work session — read HANDOFF.md and project documents, check repo state, summarize the lay of the land and wait for direction. Use this when the user opens a session, asks about the current state, or wants to know where work last left off.
argument-hint: "[optional focus]"
---

# Beginning a Session

Get your bearings before you do anything — so the first real instruction lands
on full context.

## 1 — Quota

If `~/.claude/skills/external-review/engines/quota-check.sh` exists: run it once
(`bash ~/.claude/skills/external-review/engines/quota-check.sh`) and include the
plain-text line it outputs in the summary below. If the script does not exist
(project without an external review hookup), skip this step — not an error, no
mention needed.

## 2 — Get Your Bearings

Read `HANDOFF.md` in the repo first and carefully. That is the "where am I in the
middle of things" note, only the current state, and the convention that is least
guessable from the repo. `CLAUDE.md` and `AGENTS.md` are usually already in
context; `README.md` and `docs/` fill the gaps.

If no `HANDOFF.md` exists, say so and work from the repo state — create it at the
end of the session.

## 3 — Get the Queue

The **Next up** section in `HANDOFF.md` *is* the queue. Do not reconstruct "what
is pending" from prose or commit titles.

Additionally, if the project keeps them: the open items in `KNOWN-ISSUES.md` and
the active plan files under `docs/1-plans/` or `docs/superpowers/plans/`.

## 4 — Check Repo State

Branch, uncommitted and untracked work, recent history, unpushed commits,
worktrees.

- Look deliberately at everything in `git status --untracked-files=all` that
  must never be committed.
- Name stale worktrees (merged branch, no recent commits) and **propose** the
  cleanup command — do not execute it.
- No modifying action without a task.

## 5 — Summarize

Enough to be able to choose a piece of work: what the project is, repo state,
where the last session ended, the queue, and one or two concrete entry points
that follow from both.

**Mandatory content, not a novelty filter:** If a quota check was run in step 1,
its output **always** belongs in this summary — regardless of whether it is
surprising or not. That is standard content, not a finding.

**Lead with what is surprising** — a risk, a dirty tree, a stale worktree, a
handoff that contradicts the repo. Do not sort by habit.

If `HANDOFF.md` contradicts the actual repo state, that is a finding and not a
minor matter: say which of the two is correct and how you can tell.

## 6 — Then Stop

Wait for direction. Exception: if the call already names a focus, that *is* the
direction — get your bearings, then start. Ask only what would change your next
action; routine decisions you make yourself and say how you decided.
