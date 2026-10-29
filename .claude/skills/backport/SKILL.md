---
name: backport
description: Decide whether a Dalli fix belongs on the maintained stable branches, then port it with one PR per branch. Use after a bug or security fix lands on main, or when asked "should this be backported?"
---

# Backport

## Maintained lines

| Branch | Ruby (`required_ruby_version`) | GitHub Release made by |
|---|---|---|
| `5-2-stable` | >= 3.3 | `release.yml` on tag push |
| `5-1-stable` | >= 3.3 | `release.yml` on tag push |
| `5-0-stable` | >= 3.3 | hand (`gh release create`) |
| `4-3-stable` | >= 3.1 | hand |
| `3-2-stable` | >= 2.6 | hand; security fixes only |

Check `git branch -r | grep stable` for new lines before relying on this table.

## Deciding

Backport when all of these hold:
- the bug exists on that line (check the code there, not just main)
- it causes wrong data, lost writes, a crash or a security problem
- the fix doesn't change behavior that working code depends on

Keep a fix on main for the next minor release when it does any of these:
- raises where the call used to return
- changes the accepted arguments
- changes retry or failover behavior
- is a long-standing edge case nobody has reported

Security fixes go to every line where the bug exists, including `3-2-stable`. Recommend, and let the user decide.

## Porting

For each branch, newest first, in its own worktree:

```bash
git fetch origin
git worktree add ../dalli-bp-5-1 -b fix/<topic>-5-1 origin/5-1-stable
cd ../dalli-bp-5-1
git cherry-pick -x <commit>      # or apply by hand where the code differs
```

- Adapt the change to that line's code. Keep its CHANGELOG entry under `Unreleased`.
- Run that line's checks:
  - `RBENV_VERSION=4.0.7 bundle exec rubocop`
  - `RBENV_VERSION=4.0.7 bundle exec rake`
  - Tests use fixed ports, so run the branches one after another, never in parallel.
- Run `bin/compare_refs` there too when the fix touches a hot path. Check that the script exists on that line; if not, copy it in from main for the run and don't commit it.
- PR title: the main PR's title with the line appended, such as `Store set_multi values under the keys given (5.1)`. Base it on the stable branch and link the main PR.
- After the PRs merge, remove the worktrees and branches. The release skill covers the version bumps.

Scripts: use `bash -c` for loops over branches. zsh treats `$b:l` as a modifier, and macOS bash 3.2 has no `declare -A`.
