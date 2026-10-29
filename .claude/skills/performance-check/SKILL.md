---
name: performance-check
description: Measure what a Dalli change costs in throughput and keep it fast. Use for any change under lib/ (the request path, protocol, validation, serialization, sockets, multi-key operations), before opening or merging a PR, when reviewing an outside PR that touches lib/, and when asked about performance or a regression.
---

# Performance check

Dalli is a high-performance client. Every change that touches `lib/` gets measured before its PR is opened, and the PR reports the result. Correctness and security come first, and the way to keep them is to make the necessary work cheap. Skipping that work is never the fix.

## When it applies

- **Measure it:** any change to a hot path. That covers:
  - `Client` operation methods and their argument checks
  - `Protocol::Base#request`
  - `RequestFormatter`, `ResponseProcessor`, `ResponseBuffer`
  - `ConnectionManager` reads and writes
  - `ValueMarshaller`, `ValueSerializer`, `ValueCompressor`
  - `KeyManager`, `Ring`
  - `PipelinedGetter`, `PipelinedSetter`, `PipelinedDeleter`
- **Measure it if unsure:** a change to code that runs once per connection or once per client (`connect`, option parsing). It can still matter.
- **Skip it:** docs, tests, CI and CHANGELOG-only changes. Say "no runtime change" in the PR.

## 1. Compare against the last release and main

```bash
RBENV_VERSION=4.0.7 bin/compare_refs          # latest release tag, main, working tree
bin/compare_refs main .                      # just main against the working tree
ONLY='set,quiet set 100' bin/compare_refs main .
```

- Run it with plain `ruby`, never `bundle exec`. Bundler puts this checkout's `lib/` on the load path ahead of the ref being measured.
- To measure a committed branch, pass its name as a ref.
- Close other heavy work while it runs. On a laptop, a difference under about 2% is noise, so rerun with `ROUNDS=5` before acting on a borderline number.
- The CI `Benchmarks` job only proves the benchmarks still run. Shared runners are too noisy to compare two runs there.

## 2. Judge the result

| Workload | Investigate when |
|---|---|
| Single-key ops (`get`, `set`, `incr`, `delete`) | slower by more than 2% |
| `get_multi`, `set_multi` | slower by more than 3% |
| `quiet` writes | slower by more than 3%. These don't wait on a reply, so they show CPU cost in full |

Single-key operations spend most of their time waiting on the network. A loss that shows up there means real CPU time was added. Look at `quiet` and the multi operations first: they are where added per-call work shows.

## 3. Find the cost

Time the suspect methods directly, in ns per call, with the same inputs the workload uses:

```ruby
require 'dalli'
c = Dalli::Client.new('127.0.0.1:11211')
n = 1_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times { c.send(:validate_ttl!, :ttl, 300) }
puts (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9
```

To find which commit added a cost, compare consecutive commits: `bin/compare_refs <before> <after>`.

## 4. Make it cheap without weakening it

These patterns have worked in Dalli:

- **Fast path for the common valid input.** Most calls pass an Integer TTL under 30 days, a CAS of 0, and a short ASCII String key. Accept those with a cheap type and range test first, and send everything else through the general path. That way the accepted inputs and the errors don't change. An example is `validate_ttl!` and `ttl_flag`.
- **Explicit comparisons on hot paths.** `x >= a && x <= b` is faster than `Comparable#between?`. Avoid `Integer()` with a rescue when the value is already an Integer.
- **No per-call allocation that can be hoisted.** Use frozen constants for literal arrays, hashes and strings. Keep `rubocop-performance` happy.
- **Don't validate twice at full cost.** The client checks arguments before `server.request`, so a bad value never closes the connection. The formatter re-checks only as a cheap backstop.
- **Keep work out of the per-key loop** in the multi operations: group once, look up once.
- **Per-request state is a flag, not an object.** One example is `ConnectionManager`'s `@request_sent`.

Never drop a security or correctness check to win back throughput. If the cheap version can't be found, report the cost and the trade-off to the user.

## 5. Report it

Every PR that changes `lib/` gets a **Performance** section:
- the command run
- the Ruby version
- a table of the workloads that moved, relative to the last release, or to main for a change on top of unreleased work
- a one-line explanation of any loss over the thresholds above

When the change has no measurable cost, say so in one line along with the numbers that show it.
