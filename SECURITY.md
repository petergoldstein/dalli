# Security Policy

## Supported versions

Security fixes are released for the following lines:

| Version | Supported |
| ------- | --------- |
| 5.2.x   | ✅ |
| 5.1.x   | ✅ |
| 5.0.x   | ✅ |
| 4.3.x   | ✅ |
| 3.2.x   | ✅ |
| < 3.2   | ❌ |

Upgrading to the latest release in your line is the quickest way to get fixes. Each supported line gets its own patch release when a fix applies to it.

## Reporting a vulnerability

**Please don't report security vulnerabilities in public issues or pull requests.**

Report them privately through GitHub: on the [Security tab](https://github.com/petergoldstein/dalli/security), choose **Report a vulnerability**. That opens a private advisory that only you and the maintainers can see.

A useful report includes:

- the affected Dalli version(s), Ruby version and memcached version
- the client options involved (for example the protocol, serializer or compression settings)
- steps or a small script that reproduce the problem
- what an attacker can do with it, and what they need to control to do it

## What happens next

- The report is triaged in the private advisory, and we may ask follow-up questions there.
- If it's confirmed, the fix is developed in the advisory's private fork and backported to every supported line that's affected.
- Fixed versions are released before the advisory is published. A CVE is requested through GitHub when appropriate.
- Reporters are credited in the advisory and the changelog unless they'd rather not be.

## Scope

This policy covers the Dalli gem: the memcached client and `Rack::Session::Dalli`. Vulnerabilities in memcached itself should be reported to the [memcached project](https://github.com/memcached/memcached).

Some risks come from configuration, not from a bug in Dalli. For example, the default Marshal serializer can run code from untrusted data, so values in a memcached instance that untrusted parties can write to shouldn't be deserialized with it. The [Security Note](README.md#security-note) in the README covers this.
