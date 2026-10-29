---
name: release
description: Cut a Dalli release from main or a stable branch. Covers the version bump PR, tag, gem build, the maintainer's gem push, checksum verification and the GitHub Release. Use when asked to release, bump the version, or "queue up" releases.
---

# Release

The maintainer pushes gems; RubyGems needs their OTP. Everything else can be prepared and checked here.

## 1. Before the bump

- CI is green on the branch being released.
- For a release from main, run `bin/compare_refs` against the last release, with the performance-check skill's thresholds. Put the result in the bump PR. No release ships an unexplained slowdown.
- Every user-visible change has a CHANGELOG entry under `Unreleased`, with credit for outside contributors (`(@login)`).

## 2. Version bump PR

On `release/<version>` from the branch being released:
- `lib/dalli/version.rb`: the new version.
- `CHANGELOG.md`: rename `Unreleased` to the version, and add a fresh empty `Unreleased` above it on main only.
- PR title `Prepare <version> release`. The body summarizes the changes, with PR numbers.
- Run `bundle exec rubocop` and `bundle exec rake`, then merge once green.

## 3. Tag and build

```bash
git fetch origin
git tag -a v<version> -m v<version> origin/<branch>    # the merge commit of the bump PR
git push origin v<version>
git worktree add --detach /tmp/dalli-gem v<version>     # build from a clean tree
(cd /tmp/dalli-gem && gem build dalli.gemspec)
```

Then give the maintainer the exact command, with the path to the built gem:

```
gem push /path/to/dalli-<version>.gem --otp <code>
```

## 4. Verify

```bash
curl -s "https://rubygems.org/api/v2/rubygems/dalli/versions/<version>.json?cb=$RANDOM" | jq -r .sha
shasum -a 256 dalli-<version>.gem
```

The two must match. The query string gets past the CDN cache.

## 5. GitHub Release

- **5-1-stable, 5-2-stable and main:** `release.yml` creates the release when the tag is pushed. Check it with `gh release view v<version>`.
- **Older lines (no `release.yml`):**

  ```bash
  ruby scripts/changelog_section.rb <version> > notes.md   # script from main
  gh release create v<version> --title v<version> --notes-file notes.md --verify-tag
  ```

- Whichever release is created last becomes Latest. When several lines ship together, finish by marking the highest version: `gh release edit v<highest> --latest`.

## 6. Clean up

Remove the build worktree and the `release/*` branches.
