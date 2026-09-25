---
name: deepseek-implement
description: Delegate implementation of an approved plan (or a scoped part of it) to DeepSeek 4.1 Flash via the Command Code CLI — cheap, no Claude tokens
argument-hint: "<plan-path> [instructions] | reset <plan-path> | show <plan-path>"
---

# DeepSeek Implement

Non-interactive implementation via the Command Code CLI (`cmd --print`), model `deepseek/deepseek-v4.1-flash`: DeepSeek reads the plan, edits the working tree directly, runs the project's lint/build/tests on its own work, and reports back. One persistent session per target, so a plan can be delegated in successive batches (or phase by phase) with full context retained.

State persisted under `~/.claude/skills/deepseek-implement/state/<sanitized-target>.{thread,review.txt,events.ndjson}`. `start`/`resume`/`reset`/`show` all live in this skill's own `scripts/` — self-contained, no cross-skill dependency.

## Arguments

- `<target>` — auto: start if no session, resume if one exists. Usually a plan path (`docs/1-plans/*.md`); a free-form label for unplanned work.
- Optional trailing instructions — scope control appended to the prompt, e.g. `"Implement only: <batch checkboxes>"` or `"Now implement: <next batch>"`.
- `reset <target>` — drop state, next call starts fresh.
- `show <target>` — display the latest report without calling DeepSeek.

## Execution

1. **Parse `$ARGUMENTS`**: extract action (`reset`/`show`/auto) and target.

2. **Auto** — try `start.sh` first (exit code 2 = session exists → use `resume.sh`):
   - **Start**: `bash ~/.claude/skills/deepseek-implement/scripts/start.sh --prompt-file ~/.claude/skills/deepseek-implement/prompts/implement.tpl <target> [instructions]`
   - **Resume** (next batch / additional scope): `bash ~/.claude/skills/deepseek-implement/scripts/resume.sh --prompt-file ~/.claude/skills/deepseek-implement/prompts/continue.tpl [--notes "review corrections"] <target> [instructions]`

3. **Reset**: `bash ~/.claude/skills/deepseek-implement/scripts/reset.sh <target>`

4. **Show**: `bash ~/.claude/skills/deepseek-implement/scripts/show.sh <target>`

5. **Handle the exit code**:
   - `0` — parse the trailing tag of the report:
     - `IMPLEMENTATION_COMPLETE` — proceed to review the diff yourself (`git status` / `git diff`) against the plan.
     - `IMPLEMENTATION_PARTIAL` (or no tag, the script warns) — read the report; resume with instructions for the remainder, or finish small leftovers directly yourself.
   - `3` (quota exhausted: `cmd` exit 5 rate limit or 10 no credits) — DeepSeek/Command Code is unavailable right now. Tell the user, then fall back to implementing the same scope yourself via a Sonnet subagent instead of waiting or retrying silently.
   - `4` (guard violation) — the git state changed during the run even though the permission config should have blocked writes. **Stop.** Do not trust the report. Inspect with `git status` / `git diff` / `git stash list` / `git tag` yourself, work out what changed, and decide by hand whether to keep, revert, or reset it before doing anything else. Tell the user this happened.
   - `1`/`2`/`64` — run failure (incl. an empty report), missing/existing session, or usage error; read stderr and fix the invocation (these are not silent-fallback cases).

## Notes

- **You (Claude) remain the sole reviewer of DeepSeek's output** — its own `IMPLEMENTATION_COMPLETE` tag is not a substitute for `git diff` and running the project's tests yourself. Small defects, fix directly in the tree. For a larger problem, one corrective `resume.sh` call with `--notes` explaining what was wrong and why; if that resume still doesn't land it, stop delegating and hand the remainder to a Sonnet subagent instead of a second resume.
- **Permissions are pattern rules, not a sandbox.** Runs use `--yolo` (headless `cmd` withholds the shell otherwise, and DeepSeek must run lint/tests). Deny rules still win over yolo, but `cmd` reads them only from settings files, so they live globally in `~/.commandcode/settings.json` — a symlink to `<config-repo>/commandcode/settings.json`; the scripts refuse to run if that deny list is missing. It denies git writes (`git status`/`diff`/`log`/`show` stay allowed; `branch`, `stash`, `config` are blocked entirely), the plain `rm` command, common network clients (`curl`, `wget`, `ssh`, `scp`, `gh`), dependency installs, web/MCP tools, `.env` access, edits to home dotfiles/`~/Library` and to its own settings, and shell commands naming common credential paths (`.ssh`, `.aws`, `auth.json`, …). The rules also apply when `cmd` is started by hand. Gaps to keep in mind: yolo admits directories outside the repo silently, so file tools can read **and write** outside it wherever no deny rule matches; shell deny rules match on the command string, so `/bin/rm`, `xargs rm`, `python -c 'os.remove(…)'` or a wrapper script are not caught — deletion inside the working tree has no second line of defense. The git-state guard around every run only covers git state (HEAD, branch, stash count, tag count, staged index before/after; disabled with a warning outside a git repo) — see exit code 4 above.
- Network is effectively blocked for install commands: if the plan requires a new dependency, DeepSeek reports it as a leftover — install it yourself before resuming.
- DeepSeek is instructed not to write tests (the requester owns that) and not to touch release ceremony (commits, version bumps, changelogs).
- Model defaults live in this skill's own `scripts/_common.sh` (`deepseek/deepseek-v4.1-flash`). Override per run via `DEEPSEEK_MODEL`; override the target directory via `DEEPSEEK_DIR` (defaults to the caller's cwd; `cmd` runs inside it). The scripts echo the effective values and a token-usage line from the run's result (Command Code reports no cost).
- Separate `STATE_DIR` from `codex-implement` and the `external-review/` skills — the same plan path can hold sessions in more than one of them without collision.
