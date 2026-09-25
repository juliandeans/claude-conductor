---
name: postmortem
description: Records, for a stubborn or recurring bug, why it happened and what changes as a result — as an entry in the project's decision log. Do NOT use this for ordinary fixes, only when an error occurred multiple times, stayed undetected for a long time, or shows a systematic risk.
argument-hint: "<short description of the bug or reference to the item in KNOWN-ISSUES/SOLVED>"
---

# Postmortem for a Stubborn Bug

Not for every fix — only when an error occurred multiple times, stayed
undetected unusually long, or shows a pattern that returns if nobody changes
anything. Most resolved items need nothing more than an entry in SOLVED.md (see
the `solved` skill).

## 1 — Reconstruct the Context

From the argument, from `git log`/`git diff` of the relevant commits, and from a
possibly referenced item in KNOWN-ISSUES.md or SOLVED.md: what happened, how
often, how it was fixed.

## 2 — Cause, Not Just Symptom

Two questions, answer both:

- **Why did the error happen?** The technical cause, not just "bug in file X".
- **Why was it not noticed earlier?** A missing test, unclear documentation, a
  wrong assumption that nobody checked.

If the evidence does not suffice for a clear answer, say so instead of
speculating.

## 3 — Record the Consequence

What actually changes as a result — a new test, a documented rule, a note in a
technical reference document, a new item in KNOWN-ISSUES.md if the actual fix is
postponed. A postmortem without a consequence is just a retelling and not the
purpose of the exercise.

## 4 — Enter It in the Decision Log

Append a short, dated entry to the project's decision log (e.g.
`docs/ARCHITECTURE-DECISIONS.md`) — a few sentences or bullet points, not an
essay: what was the cause, what changes because of it.

If the project has no decision log, do not create one — ask the user where it
should go.

## 5 — Report

Name the entry written and its location. No commit without an explicit task.
