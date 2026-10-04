# Security hardening plan

Two vulnerabilities were reported and fixed recently: GHSA-6wmv-xq9m-fmp7, a
command injection through numeric arguments (fixed in 5.1.1, 5.0.7, 4.3.4 and
3.2.9), and #1170, a pipelined reply-parsing bug that could return one key's
value for another (fixed in 5.2.0, 5.1.2, 5.0.8, 4.3.5 and 3.2.11). Both came
from the same two places: turning caller input into memcached's text protocol,
and parsing memcached's replies. This plan aims to find any similar bugs before
someone else does, and to harden the project around them.

> **Disclosure note.** Section 2 lists areas to audit. Suspected weaknesses
> stay out of this public file until they've been checked and, if real, fixed
> through a private security advisory.

## 1. Repository and release hardening

- [ ] **Branch protection** on `main`, `5-1-stable`, `5-0-stable`, `4-3-stable`
      and `3-2-stable`: require a pull request and passing status checks.
- [ ] **Secret scanning and push protection:** enable both.
- [x] **Least-privilege workflow tokens:** add a top-level
      `permissions: contents: read` to every workflow, and widen it only where
      a job needs more (as `release.yml` and CodeQL already do).
- [x] **Pin third-party actions by commit SHA.** Dependabot's weekly
      `github-actions` updates keep the pins current.
- [x] **`SECURITY.md`:** which release lines get security fixes, and how to
      report a vulnerability (GitHub private vulnerability reporting is
      already enabled).
- [ ] **Gem publishing:** consider RubyGems trusted publishing from CI, so
      released gems are built from tagged commits rather than on a local
      machine. MFA is already required (`rubygems_mfa_required`).
- [ ] **OpenSSF Scorecard** (optional): a workflow that keeps checking the
      items above.

## 2. Code audit, by attack surface

Each area gets a structured review. Anything suspicious gets a proof of concept
before it's treated as real, and real findings go through a private advisory.

- [ ] **Request building:** every value that reaches a command line (keys,
      namespaces including namespace procs, routing tokens, numeric flags,
      options on the bulk and pipelined paths).
- [ ] **Reply parsing:** every parser path (single-key, pipelined, multi-get
      fast path, metadata, quiet-mode draining), including edge-case replies
      such as zero-length values, values split across reads, unexpected flags
      and error lines mid-pipeline.
- [ ] **Value handling:** decompression and deserialization of values read
      from the server.
- [ ] **Key handling:** validation, namespacing and truncation of long keys.
- [ ] **TLS:** how connections are established and verified.
- [ ] **`Rack::Session::Dalli`:** session ID generation, fixation and stored
      data.
- [ ] **Logging and errors:** no credentials, keys or values leaked through
      log or exception messages.

## 3. Automated testing for these bug classes

- [ ] **Property tests on request building:** generated inputs (keys, options,
      numeric arguments) must always produce exactly one command line, with no
      CR or LF outside the protocol's framing.
- [ ] **Differential fuzzing of the reply parsers:** the same random reply
      bytes fed to the single-key and pipelined parsers must give the same
      result.

## 4. Ongoing process

- [ ] Document the advisory process used for GHSA-6wmv-xq9m-fmp7: temporary
      private fork, backports to each supported line, releases in sequence,
      then publication.
- [ ] Repeat the section 2 audit whenever a protocol feature is added.
