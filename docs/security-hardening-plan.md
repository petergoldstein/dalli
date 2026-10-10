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

- [x] **Branch protection** on `main` and every `*-stable` branch, as one
      repository ruleset ("Protect main and stable branches"): changes need a
      pull request (no approvals required, since there's one maintainer), and
      the branches can't be deleted or force-pushed. Admins can bypass only
      when merging a pull request, which covers merging a security advisory's
      private fork. Required status checks aren't set yet, because the test
      jobs are named after Ruby and memcached versions that change over time.
- [x] **Secret scanning and push protection:** both enabled.
- [x] **Least-privilege workflow tokens:** add a top-level
      `permissions: contents: read` to every workflow, and widen it only where
      a job needs more (as `release.yml` and CodeQL already do). (#1190)
- [x] **Pin third-party actions by commit SHA.** Dependabot's weekly
      `github-actions` updates keep the pins current. (#1190)
- [x] **`SECURITY.md`:** which release lines get security fixes, and how to
      report a vulnerability (GitHub private vulnerability reporting is
      already enabled). (#1190)
- [ ] **Gem publishing:** consider RubyGems trusted publishing from CI, so
      released gems are built from tagged commits rather than on a local
      machine. MFA is already required (`rubygems_mfa_required`).
- [ ] **OpenSSF Scorecard** (optional): a workflow that keeps checking the
      items above.

## 2. Code audit, by attack surface

*Status: done (2026-10-04 to 2026-10-05).*

Each area got a structured review. Anything suspicious got a proof of concept
before it was treated as real, and real findings went through private
advisories. Five were fixed together in 5.2.1, 5.1.3, 5.0.9, 4.3.6 and 3.2.12:

- [GHSA-p6pm-ch9v-44vx](https://github.com/petergoldstein/dalli/security/advisories/GHSA-p6pm-ch9v-44vx):
  pipelined `get_multi` could return another key's value after an error
  reply, and keys were measured in characters rather than bytes.
- [GHSA-4qp6-2jcr-596v](https://github.com/petergoldstein/dalli/security/advisories/GHSA-4qp6-2jcr-596v):
  routing tokens could add meta flags, and failed requests could retry forever.
- [GHSA-3553-vcg5-72jw](https://github.com/petergoldstein/dalli/security/advisories/GHSA-3553-vcg5-72jw):
  unbounded decompression and reply sizes.
- [GHSA-wr87-m4jw-29x5](https://github.com/petergoldstein/dalli/security/advisories/GHSA-wr87-m4jw-29x5):
  per-request `raw: true` ignored on some reads, and `serializer: JSON` using
  `JSON.load`.
- [GHSA-w39f-xq2m-4g8x](https://github.com/petergoldstein/dalli/security/advisories/GHSA-w39f-xq2m-4g8x):
  a forked child could resend the parent's buffered requests or end its TLS
  session.

- [x] **Request building:** every value that reaches a command line (keys,
      namespaces including namespace procs, routing tokens, numeric flags,
      options on the bulk and pipelined paths).
- [x] **Reply parsing:** every parser path (single-key, pipelined, multi-get
      fast path, metadata, quiet-mode draining), including edge-case replies
      such as zero-length values, values split across reads, unexpected flags
      and error lines mid-pipeline.
- [x] **Value handling:** decompression and deserialization of values read
      from the server.
- [x] **Key handling:** validation, namespacing and truncation of long keys.
- [x] **TLS:** how connections are established and verified.
- [x] **`Rack::Session::Dalli`:** session ID generation, fixation and stored
      data.
- [x] **Logging and errors:** no credentials, keys or values leaked through
      log or exception messages.

### Follow-ups

Lower-risk improvements the audit turned up, to be done in the open:

- [x] **TLS verification:** document that certificate and hostname checks come
      entirely from the caller's `ssl_context` (a bare `OpenSSL::SSL::SSLContext`
      verifies neither), and warn when verification is off.
- [x] **TLS handshake failure:** close the TCP socket, and raise a Dalli
      error rather than `OpenSSL::SSL::SSLError`.
- [ ] **Credentials:** stop keeping usernames and passwords from server URIs
      and options (Dalli 5 doesn't use them), so `#inspect` and error messages
      can't show them.
- [ ] **`Rack::Session::Dalli`:** document that sessions never expire in
      memcached unless `expire_after` is set, and handle a session value that
      can't be decoded without locking the user out.
- [ ] **Value terminator:** check the `\r\n` after each value instead of
      trusting the declared size.
- [ ] **Encodings:** raw and `append` values in encodings that aren't ASCII
      compatible raise `Encoding::CompatibilityError`.
- [ ] **Docs:** a `get_multi` block can see a key twice when a network error
      makes Dalli retry.

## 3. Automated testing for these bug classes

*Status: done (2026-10-05).*

- [x] **Property tests on request building:** generated inputs (keys, options,
      numeric arguments) must always produce exactly one command line, with no
      CR or LF outside the protocol's framing
      (`test/protocol/test_request_formatter_properties.rb`).
- [x] **Differential fuzzing of the reply parsers:** random reply streams for
      a multi-key get, with error replies mixed in, are fed to the pipelined
      parser in random-sized chunks, and each hit is also parsed by the
      single-key parser. Both must return exactly the generated keys and
      values (`test/protocol/test_response_processor_fuzz.rb`).

## 4. Ongoing process

- [ ] Document the advisory process used for GHSA-6wmv-xq9m-fmp7 and the
      five advisories above: temporary private fork, backports to each
      supported line, release PRs once fixes are ready to ship, releases in
      sequence, then publication.
- [ ] Repeat the section 2 audit whenever a protocol feature is added.
