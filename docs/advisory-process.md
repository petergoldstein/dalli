# Security advisory process

How a vulnerability in Dalli goes from a private report to published fixes.
[SECURITY.md](../SECURITY.md) is the reporter's view; this is the
maintainer's. It's the process used for GHSA-6wmv-xq9m-fmp7 and the advisories
that followed it.

Until the advisory is published, nothing about the vulnerability goes into
public issues, pull requests, commits, branch names or CHANGELOG entries.

## 1. Triage

- Reports arrive as private advisories through the repository's Security tab.
  A report found by the maintainers starts as a draft advisory too.
- Reproduce it on the latest release before treating it as real, ideally with
  a small script or a failing test.
- Check every supported line (see SECURITY.md), reading the code on each
  stable branch rather than assuming it matches main. Record the affected
  version ranges in the advisory.
- Fill in the advisory's description, severity and affected versions as they
  become clear. Ask the reporter follow-up questions in the advisory.

## 2. Fix in the private fork

- Create the advisory's temporary private fork and develop the fix there, with
  a test that fails before it. Related findings can share one advisory and
  fork.
- Base the branches on the current tip of main and each stable branch.
- Run each line's checks: `bundle exec rubocop`, `bundle exec rake`, and
  `bin/compare_refs` for anything under `lib/` (see
  [performance-check](../.claude/skills/performance-check/SKILL.md)).
- CI doesn't run in the private fork, so run the suite on JRuby and
  TruffleRuby locally too when the fix touches I/O or parsing.

## 3. Backport

- Port the fix to every supported line where the bug exists, one branch per
  line in the fork. Adapt it to that line's code, and keep 3.2 compatible
  with Ruby 2.6.
- If main or a stable branch moves before release, rebase the fork's branches
  onto it and rerun the checks. Keep the old head on a backup branch until
  the release ships.

## 4. Prepare the releases

- On each fork branch, add a commit that bumps `lib/dalli/version.rb` and
  moves `Unreleased` in the CHANGELOG under the new version, with a
  `Security:` section describing the fix (credit the reporter unless they'd
  rather not be). Pending bug fixes on that line can ship in the same release.
- Write the advisory's text for publication: what's affected, the impact,
  what an attacker needs to control, the fixed versions and any workaround.
  Use the version numbers the releases will get.
- Agree a release date with the reporter if they're coordinating disclosure.

## 5. Release

On release day, for each line, newest first:

1. Push the branch to the public repository as `release/<version>` and open a
   pull request titled `Release <version> (security fixes)`. The body says
   only that the release has security fixes, with details to follow in the
   advisory.
2. Merge once CI is green. This is the first CI run the fix gets.
3. Tag, build and push the gem, and verify the checksum, following
   [the release steps](../.claude/skills/release/SKILL.md).

Then create the GitHub Releases (`release.yml` does this on 5.1, 5.2 and
main) and mark the highest version Latest.

## 6. Publish

- Once every fixed gem is on RubyGems, publish the advisory, and request a CVE
  from it if one wasn't assigned already.
- Open a pull request on [rubysec/ruby-advisory-db](https://github.com/rubysec/ruby-advisory-db)
  adding `gems/dalli/<GHSA id>.yml`, with the patched versions for each line.
  Add the `cve:` field once GitHub assigns one. That repository asks for no
  AI-attribution lines in commits or pull requests.
- Delete the temporary private fork, the `release/*` branches and any local
  backup branches.

## 7. Follow up

- Look for the same class of bug elsewhere in the code (the
  [hardening plan](security-hardening-plan.md) records past audits).
- Add a test, fuzz case or property test that would have caught it.
