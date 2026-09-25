## General Working Approach

Before non-trivial work, read the project-local instructions and the documents
relevant to the task: `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`, approved plans,
architecture and contract documents. Project-local rules are more concrete than
this file and take precedence over it.

Ask a clarifying question only when the repository, documentation and existing
code do not settle the decision. Do not invent missing requirements.

The user is not a professional developer: explain everything they are to decide
in simple words without jargon — and if a decision cannot be explained simply,
that is usually a sign that the task is unnecessary.

## Where Which Information Goes

Every piece of information has exactly one place. Storing it additionally
somewhere else is the duplicated work to be avoided — and nothing may end up
existing only in the conversation at the end of a session.

| Information | Place |
|---|---|
| **Where I stand, what comes next** | `HANDOFF.md` in the repo |
| **Durable why** — decisions, trade-offs | the project's decision log (e.g. `docs/ARCHITECTURE-DECISIONS.md`) |
| **Known problems that nobody fixes** | `KNOWN-ISSUES.md` or the equivalent |
| **Long-term project state** | `PROJECT_STATUS.md` or the equivalent |
| **Technical reference** — how something works, pitfalls | the topic-related documents under `docs/` |
| **Specifications and plans** | `docs/superpowers/specs/` and `docs/1-plans/` |

`HANDOFF.md` is the short-term memory: four sections — Status, Next up, Active
plan files, Open questions. **Overwritten** at the end of a session, not
appended to; the history lives in Git. If it grows beyond one screen, the excess
belongs in one of the long-term documents. A bulky document is not maintained
and quietly goes stale — a lean one survives.

If a repo has no `HANDOFF.md`, create it at the first end of session.

## Approach to Changes

You decide the classification deliberately at the start.

**Trivial** — one-liner, typo, rename, text change, a narrowly scoped fix at a
place you have already read. Just do it; the ceremony would cost more than the
change.

**Small and manageable** — a well-defined feature, a bugfix with a known cause,
an additional test, a refactoring across a few files. `deepseek-implement`
implements it directly (see below); afterwards you review the full diff yourself
and have a fast external engine read it (CommandCode Flash default). No
brainstorming, no plan document, no plan review — the ceremony costs more here
than it finds.

**Large or delicate** — multi-step overhauls, anything touching architecture or
several layers, bugfixes with an unclear cause, work spanning many files:

1. `superpowers:brainstorming` — **no code before an approved design**
2. `superpowers:writing-plans`
3. `external-plan-review` — a design flaw is cheapest to catch here
4. `superpowers:subagent-driven-development`
5. `external-code-review` — the entire diff against the plan
6. `superpowers:finishing-a-development-branch`

If you are unsure which of the two levels something belongs to, ask in one
sentence instead of running the more expensive one just in case.

For bugs with an unclear cause, `superpowers:systematic-debugging` comes before
every repair proposal. Before every completion report,
`superpowers:verification-before-completion` applies.

For migrations, persistence, data integrity, deletion, concurrency, public
API/command contracts or irreversible changes, the large level always applies —
regardless of how small the diff looks.

## Delegating to Subagents

You coordinate, review and decide — you have the typing done.

- **Every subagent is given its model explicitly** — never let it inherit one.
  `model: "sonnet"` for implementation and analysis, `model: "haiku"` for
  mechanical work (renaming, formatting, blunt search-and-replace). If the main
  session runs on Opus, an inheriting subagent pays Opus prices for work that
  Sonnet does just as well. Opus for a subagent only if you can name the reason.
- **Broad research** goes to `Explore` before you read many files yourself.
- **One subagent per task**, fresh context.
- **The briefing must be self-contained.** Subagents inherit nothing from this
  conversation: goal, scope boundary, binding documents, the permitted file
  paths listed individually, acceptance criteria, required tests, explicitly
  excluded changes.
- Do not work on the same task in parallel yourself. Do not start the same task
  more than once without a concretely named missing finding.
- If a subagent fails, **report it** and do not silently fall back to
  implementing it yourself.

Risky or widely spreading overhauls run in a separate worktree
(`superpowers:using-git-worktrees`).

## DeepSeek as Implementer (deepseek-implement)

Writing code goes first to `deepseek-implement` (DeepSeek 4.1 Flash via
CommandCode, costs no Claude quota) instead of a Sonnet subagent — at the small
level as well as for the implementation tasks of the large level (the
implementer role in `superpowers:subagent-driven-development`; you then make the
commit per task). The same self-contained briefing as for a subagent, as an
instruction block.

- Review stays entirely with you: `git status`, the whole diff, tests yourself.
- Small defects you fix yourself; larger ones get **one** correction run
  (`resume.sh --notes`), after which a Sonnet subagent takes over.
- Quota empty (exit 3) or run failed → Sonnet subagent, and you say that DeepSeek
  failed. Exit 4 (git guard) → stop immediately, investigate yourself, report to
  the user.
- Not to DeepSeek: analysis, judgment and architecture questions, reviews — and
  tasks that need deletion, git writes or package installations (they are
  blocked; you handle them yourself).
- The blocks are pattern rules, not a sandbox: DeepSeek can read and write
  outside the repo where no rule applies, and deletion via workarounds
  (`/bin/rm`, scripts) is not detected; the git guard only catches git state
  changes. The block list lives globally in `~/.commandcode/settings.json` (a symlink to
  `<config-repo>/commandcode/settings.json`; see `examples/commandcode-settings.json`) and also applies to `cmd` in its
  own terminal.

## Gemini as Sub-Worker (agy)

Antigravity CLI, its own quota — separate from Claude and from Codex. Invocation
exclusively via `~/.claude/agy/agy-run.sh` and the subagents `gemini-delegate`
(broad read tasks) and `gemini-precheck` (pre-filter before Sol).

- **Broad reading with a short result goes to Gemini:** condense large diffs and
  logs, changelogs from many commits, semantic repo surveys, doc-versus-code
  comparison, test gaps. Guideline from ~15 files or ~50k tokens of reading.
- **Not to Gemini:** lexical searches (`rg`, `Explore`), dead-code and dependency
  audits — there are exact tools for that, which prove instead of estimate.
  Likewise screenshots and PDFs (Claude reads those itself), architecture and
  judgment questions, and never the final review. Sol remains the last instance.
- **Video is the only multimodal case** that goes to Gemini.
- **One large call instead of many small ones.** Every agy call carries 14–25k
  tokens of baseline load; fan-out multiplies it. That is exactly the opposite
  of the fan-out for Sonnet subagents.
- **Scoping is mandatory.** Prefer `--file`/`--base` (only copies of the named
  files), otherwise `--dir` explicitly — never a repo root: databases, backups
  and `.env` files live there. An access outside the scope aborts the run and
  consumes the quota anyway. Gemini uses no shell (every command is refused
  headless); it only reads files with a known path, listing/searching does not
  work.
- **No `--dangerously-skip-permissions`** outside expressly approved batch runs.
  Write protection depends on this: in print mode every write access is
  automatically refused because nobody can consent.
- **Gemini output is an opinion, not a finding.** Every finding that leads to a
  change is verified against the real code beforehand.
- **The wrapper checks the quota before every run** (`/usage` costs 0 tokens).
  No silent downgrade — every switch to a weaker model is reported and taken
  into account when evaluating.
- **On the cross-check, never fall back to the Claude models in agy.** That
  would be Claude checking Claude, and thus the same blind spot. If Gemini is
  not enough: wait for the 5-hour window, Luna via Codex, or to Sol without a
  pre-filter — and say that the pre-filter failed.
- **Full reports in files** under `~/.claude/agy/runs/`, only short versions in
  the context. `runs.log` collects model, consumption and quota level per run —
  the thresholds are calibrated from that.

## External Cross-Check

Superpowers' own reviews run on Claude subagents — Claude checking Claude. That
finds sloppiness, but not shared blind spots. The external review skills exist
for that: `external-plan-review` (plan, with verdict), `external-code-review`
(diff, read-only), `external-ask` (free second opinion, purely advisory —
agreement is a weak signal, **disagreement a strong one** and belongs in front
of the user). `external-usage` shows the quotas of all engines.

Four engines are available: Codex (GPT-Sol/Luna), OpenCode-Go
(DeepSeek-Flash/Pro), Antigravity (Gemini-Flash/Pro), CommandCode (Flash default
switches automatically by time of day between Mimo V2.5 Pro Mon-Fri 03-06 and
08-12 o'clock and DeepSeek Flash 4.1 otherwise, incl. Sat/Sun;
`z-ai/glm-5.3-flash` as a selectable alternative for a deliberately different
second opinion, plus GLM-5.3 for Oracle-like final questions). CommandCode's
Flash default is the first choice for fast coding work as well as for fast,
non-critical reviews/small findings; outside the expensive hours, CommandCode
(Flash 4.1) together with Gemini is the recommended combination for a
deliberate second opinion. The choice of engine and **default model** for
routine turns runs automatically,
based on the quota level that `/start-session` checks once at the start of a
session via `external-review/engines/quota-check.sh`. No clarifying question for
this routine choice — on quota exhaustion in the middle of a session, the
respective skill switches to the next engine from the priority list on its own.

For a **premium model** (Sol, DeepSeek-Pro, GLM-5.3) this does not apply: if a
task justifies it (final review after a larger overhaul, Oracle-like question,
architecture-relevant plan/diff), the respective skill briefly asks which
premium model should be used — never switch on your own, not even with an
obvious benefit.

Before irreversible steps — migration, data deletion, release, push — the
external cross-check is mandatory.

If no quota is left for an external engine, you fall back to the Claude-internal
review and **say that the external check failed** — instead of silently skipping
it.

## Scope and Working Tree

Preserve existing changes in the working tree. Do not overwrite, remove or
reformat anything that is not part of the task.

Do not change any files outside the current repository and no global Claude, Git
or shell configuration without an explicit task. No dependency, lockfile,
toolchain or version changes outside the confirmed scope.

Do not read or show any secrets, API keys, tokens or credential files.

## Review and Completion

**The user does not review diffs themselves. You are the only substantive review
instance.** Everything else follows from that.

After every writing subagent, check for yourself `git status`, the full diff,
`git diff --name-only` against the paths listed in the briefing, the relevant
contracts and the actual test results. A subagent's report is not proof — the
self-report about its own scope is, by experience, unreliable.

Claim only what is backed by the diff, source code or test output. Run the
smallest relevant tests first and expand only if needed. Report the commands run
as well as PASS, FAIL or "not run" unambiguously.

If you call a failed gate "flaky", "pre-existing" or "environment-related", that
is a claim requiring evidence: the same error must be reproduced on an unchanged
state. Without that evidence the gate counts as red.

If the result deviates from the task — more changed than commissioned, different
files than expected — say so actively.

A completion report is a receipt, not a place to raise new things. What is
still worth mentioning belongs in `HANDOFF.md` or the responsible document
beforehand.

## Git and Release

Subagents may not commit, push, tag, merge, rebase, reset, stash, clean, switch
branches or manipulate the index. Only exception: the commit per plan task
within `superpowers:subagent-driven-development`, in the worktree provided for
it.

The main session also does not commit and push on its own initiative as long as
the user has not explicitly commissioned it — except in the provided completion
via `end-session`: there the local commit is the normal case (see there), because
an unpushed commit can always be undone safely. Push always requires a task in
any case.

Stage with an explicit path, **never `git add -A` or `git add .`** — check with
`git diff --cached --stat` that exactly what was commissioned is staged.

Leave no Claude or tool signatures in Git or forge artifacts: no
`Co-Authored-By` trailer, no session links, no "Generated with Claude Code" in
commits, PRs, issues or comments. These artifacts contain exclusively the
subject-matter content of the change.
