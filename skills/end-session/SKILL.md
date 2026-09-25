---
name: end-session
description: End a work session — nothing may remain only in the conversation. Triage untracked files, update stale documents, route open threads, overwrite HANDOFF.md. Use this when the user closes the session, wants to clean up, or is done for the day.
argument-hint: "[optional note about what is still open]"
---

# Ending a Session

Leave the repo, documents and the queue so that **nothing lives only in this
conversation**. That is the whole purpose: the user reads neither diffs nor the
conversation.

## 1 — Triage Untracked Files

Put every file from `git status --untracked-files=all` into exactly one category:
commit, deliberately leave out (gitignore or a line in `HANDOFF.md`), or delete.

**Delete only what you created yourself in this session and whose purpose is
recorded elsewhere.** Anything you cannot classify stays.

If the project keeps a task checklist (in my setup `docs/OMNIFOCUS.md`), tick off there every item that was completed in
this session (`[ ]` → `[x]`) — change nothing else in the file.

## 2 — Bring Stale Documents Up to Date

The basis is what was actually changed in this session — not your memory of it.
Which documents a project keeps is stated in its `CLAUDE.md` or `AGENTS.md`.

Do not create new documents and do not restructure anything without asking.

## 3 — Route Open Threads

Read through the session, not just the diff — it is about what never touched a
file. The table "Where Which Information Goes" in the global `CLAUDE.md` covers
the normal case. Three special cases:

- **Observation too thin to act on**, or a question only the user can answer →
  under *Open questions* in `HANDOFF.md`, expressly with a note of how thin the
  evidence is.
- **Risk or fact that no file records** — single copies, unbacked-up data,
  manual steps → into `KNOWN-ISSUES.md` *and* as a pointer line in the document
  someone reads before stumbling over it.
- **Limitation on an already noted item** → onto that item, not into the chat.

No prose list of "next steps" in the report. What is pending is in `HANDOFF.md`.

## 4 — Overwrite HANDOFF.md

Four sections, **overwritten instead of appended to** — only the current state,
the history lives in Git:

```markdown
# Handoff

**Status:** <date> · Branch `<branch>` · HEAD `<sha>`

## Status
## Next up
## Active plan files
## Open questions
```

"Nothing is in progress" is a valid answer. Do not pin a commit SHA and no
deploy state that you have not checked yourself in this step — instead name the
command that checks it.

If the file becomes longer than one screen, the excess belongs in a long-term
document. That is exactly what such notes otherwise die of.

## 5 — Record the Durable Why

The decisions and trade-offs of this session go into the project's decision log.

## 6 — Commit

**A local commit is automatically the completion here** — no clarifying question
needed, an unpushed commit can always be undone safely. The only exception: the
user has expressly said for this session that nothing should be committed — then
it stays a proposal without a commit.

Otherwise: **stage with an explicit path, never `git add -A` or `git add .`**.
Confirm with `git diff --cached --stat` that exactly the batch from step 1 plus
what was written in steps 2–5 is staged — and nothing else. If the diff contains
recognizably off-topic or unclear changes that do not belong in a commit, leave
exactly those out and commit the rest anyway — in the report you name what you
left out and why. If several independent topics belong in the remaining diff,
split them into several commits instead of building one catch-all commit. No
tool signatures in the message.

Pushing always requires a task in any case; without a remote you say that it
stays local.

## The Report Is a Receipt

It is **not a place to raise new things**. If something else worth mentioning
comes to mind while writing, it is not routed — so route it.

Report: what was committed (or what would need to be committed), which items
moved where, what each document now records, and whether the branch is in sync.

If a step fails, say so instead of working around it.

*In a worktree:* merge to main before pushing — and that only on request.
