# agent/

You are one of several Claude sessions working this repo at once. Four verbs, in order.

| Script | When |
| --- | --- |
| `start.ps1 -Task <name>` | Before you touch anything. Worktree, branch `agent/<name>`, Factorio instance. |
| `integrate.ps1 -Message "<terse>"` | After review 1. Commits your work, pulls `main` in, runs the ladder. |
| `land.ps1` | After review 2. Commits the merge and puts it on `main` with `--no-ff`. |
| `finish.ps1 -Task <name>` | After landing, from the primary worktree. Removes everything. |

The procedure and the rules are in `CLAUDE.md`; this file is the mechanics.

## What the lock is for

`integrate.ps1` and `land.ps1` take a lock (`tools/lib/lock.ps1`) living in the shared git
directory, so all worktrees see one. Both release it before returning, and **neither holds it
while a human reads a diff** — an agent that did would stall every other agent for as long as
the review took.

Because `integrate.ps1` merges `main` in under the lock and `land.ps1` refuses if `main` has
moved since, the merge into `main` cannot conflict. Every conflict is resolved in your own
worktree, which is the only place you are allowed to resolve one.

## When review 2 is skipped

`integrate.ps1` asks whether `main` was already an ancestor of your branch *before* it merges —
afterwards there is no way to tell "already in" from "merged cleanly". If nothing came in, the
integrated tree is byte-identical to the one review 1 approved, so the script says so and you go
straight to `land.ps1`. Review 2 exists to catch a change that was fine alone and breaks in
combination; with no combination it costs a person's attention and buys nothing. Conflicts always
mean something came in, so the resume path never skips it.

## Two traps

- **`finish.ps1` unlinks junctions before it deletes anything, and so must you.** A worktree
  holds `factorio\` pointing at the install and `.factorio\<task>\data\mods\<mod>` pointing at
  the primary `src\`. Measured: **`git worktree remove --force` follows a junction and deletes
  the target** — run on an un-unlinked worktree it takes the real install and the real `src/`
  with it. PowerShell's own `Remove-Item -Recurse` and `Get-ChildItem -Recurse` do *not* follow
  one, so git is the specific thing to be careful of. `finish.ps1` asserts nothing is still
  linked before it calls git, and prints the surviving `src/` file count afterwards.
- **Conflicts release the lock and stop.** `integrate.ps1` exits 3 with the file list; resolve
  them and run the same command again with no arguments. It detects the merge already in
  progress and continues rather than starting over. If `main` moved while you were resolving it
  says so and you start again — the resolution was made against a tree that no longer exists.

## Exit codes

`0` fine · `1` refused or the ladder failed · `3` conflicts to resolve · `4` `main` moved,
re-integrate.
