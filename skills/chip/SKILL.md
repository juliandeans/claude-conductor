---
name: chip
description: Creates a task chip for a new session — for the follow-up task Claude just suggested in this conversation, otherwise for the top item from "Next up" in HANDOFF.md. Use this at the end of a session when the user wants to offload the next step into a new chat.
argument-hint: "[optional item, if not the last suggested one or the top one in \"Next up\"]"
---

# Task Chip for the Next Session

One chip per invocation, for exactly one follow-up task.

## 1 — Source of the Task

**Priority 1:** Has this conversation just proposed a concrete next step — e.g.
as part of `end-session` or otherwise along the way? Then that one applies,
without further searching.

**Priority 2:** Only if no such proposal exists in the conversation: take the top
item from **Next up** in `HANDOFF.md`. If `HANDOFF.md` is missing or the section
is empty, say so and stop — do not invent a task.

An item named by argument takes precedence over both.

If **Next up** contains several clearly independent items and none of them was
just proposed in the conversation, briefly ask which one is meant.

## 2 — Build the Task

- **Title:** under 60 characters, starts with a verb.
- **TL;DR:** one to two sentences for the tooltip.
- **Prompt:** self-contained — the new session does not know this conversation.
  **Always** starts with: "First run `/start-session`. Then: ...". After that the
  actual task with enough context to get started without a clarifying question:
  repo path, relevant parts from `HANDOFF.md`, reference to an active plan file,
  if present.

## 3 — Create the Chip

With `cwd` = current repo.

## 4 — Confirm

Briefly say what is in the chip. The item stays in `HANDOFF.md` — the chip does
not remove it from the queue; `/end-session` in the new session does that once
the task is complete.
