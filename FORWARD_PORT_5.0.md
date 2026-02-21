# Forward-Porting Pipeline Optimizations to 5.0

Tracks what's needed to bring the performance optimizations from PR #1072
(`perf/pipeline-optimizations`, branch `v4.3`) into the `main` branch (5.0.x).

## Background

PR #1072 reduces object allocations in pipelined get response processing,
narrowing the `get_multi` regression vs Dalli 2.7.11 from -19% to -10%.
The changes were made against `v4.3` where both binary and meta protocols exist.
On 5.0, the binary protocol was removed — only meta remains.

## File Mapping (4.3 → 5.0)

| 4.3 path | 5.0 path | Notes |
|----------|----------|-------|
| `lib/dalli/protocol/response_buffer.rb` | Same path | Identical on both branches — **no changes needed**, already applied |
| `lib/dalli/protocol/meta/response_processor.rb` | `lib/dalli/protocol/response_processor.rb` | File moved up one directory level in 5.0 |
| `lib/dalli/protocol/binary/response_processor.rb` | *(removed in 5.0)* | Skip — binary protocol doesn't exist |
| `lib/dalli/protocol/base.rb` | Same path | Minor 5.0 differences (auth removal), but `pipeline_next_responses` is the same |
| `lib/dalli/pipelined_getter.rb` | Same path | Only diff is 5.0 removed `require 'set'` |

## Changes to Apply

### 1. ResponseBuffer — already done

`lib/dalli/protocol/response_buffer.rb` is identical between `v4.3` and `main`.
Since our optimization was applied to the 4.3 version of this file, and 5.0's
copy is the same starting point, the patched 4.3 file can be copied directly.

Alternatively, cherry-pick will apply cleanly.

### 2. Meta ResponseProcessor (`lib/dalli/protocol/response_processor.rb`)

The 5.0 file still has the un-optimized `getk_response_from_buffer` with the
same helper methods (`contains_header?`, `header_from_buffer`,
`tokens_from_header_buffer`). Apply the same changes:

- **`getk_response_from_buffer`**: Add `offset = 0` parameter. Replace
  `contains_header?` call with inline `buf.index(TERMINATOR, offset)`.
  Inline the header parsing (byteslice + split) instead of calling
  `tokens_from_header_buffer`. Update all `buf.bytesize >= resp_size`
  checks to use `offset + resp_size`. Use `buf.byteslice` instead of
  `buf.slice` for body extraction.
- **Remove** `contains_header?`, `header_from_buffer`, and
  `tokens_from_header_buffer` methods (all inlined).

The 4.3 binary response processor changes can be skipped entirely.

### 3. Protocol::Base (`lib/dalli/protocol/base.rb`)

The `pipeline_next_responses` method is identical between 4.3 and 5.0.
Apply the same change:

- Accept `&block` parameter
- When block given: `yield key, value, cas`
- When no block: lazy-init `values ||= {}` with fallback `values || {}`
- Add rubocop disable/enable for `Metrics/AbcSize`,
  `Metrics/CyclomaticComplexity`, `Metrics/PerceivedComplexity`

Note: 5.0's `base.rb` removed auth methods and added `warn_uri_credentials`,
but `pipeline_next_responses` is unaffected.

### 4. PipelinedGetter (`lib/dalli/pipelined_getter.rb`)

Three changes, all identical to the 4.3 patch:

- **`process_server`**: Use block form of `pipeline_next_responses`
  (yield `key, value, cas` instead of iterating returned hash)
- **`servers_with_response`**: Replace `server_map` hash with
  `servers.map(&:sock)` + `Array#find` linear scan
- **`remaining_time` and `process`**: Replace `Time.now` with
  `Process.clock_gettime(Process::CLOCK_MONOTONIC)`

### 5. Benchmark script (`bin/compare_versions`)

Copy as-is. Update the version-specific protocol handling if needed (5.0
doesn't support `:binary`, so the script's `DALLI_PROTOCOL=binary` path
would only be used when testing older gem versions from RubyGems).

## Recommended Approach

Cherry-picking the optimization commit should apply with minimal conflicts:

```bash
git checkout main
git cherry-pick <sha-from-v4.3>
```

**Expected conflicts:**
- `lib/dalli/protocol/meta/response_processor.rb` will conflict because this
  file was moved to `lib/dalli/protocol/response_processor.rb` in 5.0. Resolve
  by applying the same diff to the 5.0 file path instead.
- `lib/dalli/protocol/binary/response_processor.rb` changes will need to be
  dropped (file doesn't exist in 5.0).

After resolving, verify:
```bash
bundle exec rubocop
bundle exec rake
```

## Verification

Run the same benchmarks as PR #1072 to confirm the improvement carries over:

```bash
# Baseline (stock 5.0.0 from RubyGems)
DALLI_VERSION=5.0.0 DALLI_PROTOCOL=meta ruby bin/compare_versions

# Patched local code
ruby -I lib -e '<inline benchmark>' # or use bin/benchmark
```
