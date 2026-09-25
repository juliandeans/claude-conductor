---
name: solved
description: Moves resolved items from KNOWN-ISSUES.md into a SOLVED.md, sorted by area. Use this when KNOWN-ISSUES.md becomes unwieldy or the user wants to archive resolved items.
argument-hint: "[optional path to KNOWN-ISSUES.md]"
---

# Archive Resolved Items

KNOWN-ISSUES.md is the worklist for open problems — not an archive for resolved
ones. Move resolved items completely and unchanged into a SOLVED.md alongside
it, so the worklist stays compact and the history is still preserved.

## 1 — Find and Read KNOWN-ISSUES.md

Without a path in the call: `KNOWN-ISSUES.md` in the current repo root. If none
exists, say so and stop — nothing to archive.

Read the document's legend (usually a "Legend" section or a status list at the
beginning). It defines which word means "resolved" — different from project to
project.

## 2 — Identify Resolved Items

An item counts as resolved if its status field matches what the legend defines
as complete (typically `done`, but `fixed`, `solved`, `closed` also count if the
document uses these words that way). `in progress`, `planned`, `later`,
`documented` (in the sense of "only documented, not fixed") stay.

When unsure whether an item is really finished: leave it and name it in the
report, instead of guessing.

## 3 — Check Cross-References

Some items are referenced from other places in the document (e.g. "see A10",
"falls under D9"). That is no reason to leave a resolved item in place — but
name these cases in the report so it is clear that a reference now points to
SOLVED.md instead of KNOWN-ISSUES.md.

## 4 — Move to SOLVED.md

If no SOLVED.md exists alongside KNOWN-ISSUES.md yet, create it: same file-
header style (title, "Status: <date>"), same area structure as the original (the
letter/chapter headings, e.g. "A. Small, isolatable work").

Move every resolved item **completely and verbatim** — including finding,
implementation, validation, gate — under the matching area heading in SOLVED.md.
Do not invent a new structure; adopt the original's.

**IDs are never reassigned.** If, for example, A7 remains as the only open item
in area A, it stays A7 — do not fill gaps, no renumbering.

## 5 — Remove from KNOWN-ISSUES.md

Delete the item completely from KNOWN-ISSUES.md, including its row in any
overview/priority table at the top of the file. Update the file's "Status:" date.

## 6 — Report

The report is a receipt: which items moved where, which stayed for what reason
(uncertainty, open cross-references). No commit without an explicit task.
