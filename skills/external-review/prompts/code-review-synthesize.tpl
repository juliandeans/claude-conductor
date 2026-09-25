The iteration loop has converged (or been capped). Produce a **consolidated final review** for archival.

This is the canonical record of how this change was reviewed. Cover every finding from the whole thread — addressed, overridden, or open — with final status and `file:line` references.

## Format

If `.claude/skills/TRIP-review/cr-template.md` exists in this project, read it and produce output conforming to its markdown skeleton. If that exact path does not exist, do NOT search elsewhere for it — this project does not use TRIP, use this generic skeleton instead:

```markdown
# Code Review: <title>

**Review Date**: <YYYY-MM-DD>
**Version**: <x.y.z>
**Files Reviewed**: <from git diff --name-only HEAD>
**Plan**: <path or "no plan — unplanned change">

## Findings

<file:line, severity (Critical/Major/Minor/Suggestion), disposition>

## Checklist

<pass/caveat per review priority: correctness, security/safety, plan conformance, practical concerns>

## Verdict

<APPROVED / APPROVED with observations / NEEDS REVISION>
```

Fill-in guide:
- **Title**: feature/change name from `{{TARGET}}`
- **Review Date**: today's date (YYYY-MM-DD)
- **Version**: leave as `<x.y.z>` (requester fills from TRIP-2 Step 2)
- **Files Reviewed**: from `git diff --name-only HEAD`
- **Plan**: `{{TARGET}}` if path under `docs/1-plans/`, else "no plan — unplanned change"
- **Findings**: every finding from all rounds with `file:line` and disposition
- **Checklist**: tick passing sections, caveat the rest
- **Verdict**: `APPROVED` / `APPROVED with observations` / `NEEDS REVISION`

Output only the rendered markdown — no preamble or commentary.

## Sentinel

After the review, on its own line: `PROMOTION_READY`

{{EXTRA_PROMPT}}
