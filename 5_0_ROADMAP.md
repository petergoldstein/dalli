# Dalli Roadmap: Path to v5.0

## Executive Summary

This roadmap outlines the evolution of Dalli from v4.x through v5.0, focusing on:
1. Deprecating and removing the binary protocol
2. Expanding meta protocol support (especially thundering herd features)
3. Performance improvements from Shopify's fork
4. Codebase simplification and modernization

---

## Version Strategy

### v4.x Series (Incremental, Non-Breaking)
- Add deprecation warnings for binary protocol
- Add new meta protocol features
- Backport performance improvements from Shopify/dalli
- Fix outstanding bugs

### v5.0 (Breaking Changes)
- Remove binary protocol entirely
- Remove SASL authentication (meta protocol doesn't support it)
- Require memcached 1.6+ (meta protocol minimum)
- Simplify codebase structure

---

## v4.1.0 - Deprecation & New Features ✅ COMPLETE

### 1. Deprecate Binary Protocol
**Files:** `lib/dalli/protocol/binary.rb`, `lib/dalli/client.rb`

- Add deprecation warning when `protocol: :binary` is used
- Add deprecation warning when SASL credentials are provided
- Update documentation to recommend meta protocol
- Note: Binary remains functional, just deprecated

### 2. Add `set_multi` Operation
**Reference:** Shopify/dalli#59 (similar pattern), Shopify/dalli#39

**Files to create/modify:**
- `lib/dalli/pipelined_setter.rb` (new)
- `lib/dalli/client.rb`
- `lib/dalli/protocol/meta.rb`
- `lib/dalli/protocol/meta/request_formatter.rb`

```ruby
# New API
client.set_multi({ 'key1' => 'val1', 'key2' => 'val2' }, ttl, options)
```

Currently users must use `quiet { }` blocks for pipelined sets, which is awkward.

### 3. Add `delete_multi` Operation
**Reference:** Shopify/dalli#59

**Files to create/modify:**
- `lib/dalli/pipelined_deleter.rb` (new)
- `lib/dalli/client.rb`
- `lib/dalli/protocol/meta.rb`
- `lib/dalli/protocol/meta/request_formatter.rb`

```ruby
# New API
client.delete_multi(['key1', 'key2', 'key3'])
```

### 4. Thundering Herd Meta Protocol Flags
**Reference:** memcached protocol.txt, Shopify/dalli#46

Added support for thundering herd protection flags:

**For `mg` (get) - implemented:**
| Flag | Purpose | Use Case |
|------|---------|----------|
| `N(ttl)` | Create stub on miss | Thundering herd protection |
| `R(ttl)` | Win recache if TTL below threshold | Thundering herd protection |

**Response flags parsed:**
| Flag | Purpose |
|------|---------|
| `W` | Client won recache rights |
| `X` | Item marked stale |
| `Z` | Another client already won recache |

**For `md` (delete) - implemented:**
| Flag | Purpose | Use Case |
|------|---------|----------|
| `I` | Mark stale instead of deleting | Graceful invalidation |

**Metadata flags - implemented:**
| Flag | Purpose | Use Case |
|------|---------|----------|
| `h` | Return hit status (0/1) | Metrics/debugging |
| `l` | Seconds since last access | Cache analytics |
| `u` | Skip LRU bump | Read without affecting eviction |

**Files:**
- `lib/dalli/protocol/meta/request_formatter.rb`
- `lib/dalli/protocol/meta/response_processor.rb`

### 5. `get_with_metadata` and Metadata Flags
**Status:** ✅ COMPLETE

New client-level method for advanced cache operations:

```ruby
# Get value with metadata
result = client.get_with_metadata('key')
# => { value: "data", cas: 123, won_recache: false, stale: false, lost_recache: false }

# Get with hit status
result = client.get_with_metadata('key', return_hit_status: true)
# => { ..., hit_before: false }  # First access

# Get with last access time
result = client.get_with_metadata('key', return_last_access: true)
# => { ..., last_access: 42 }  # Seconds since last access

# Skip LRU bump (read without affecting eviction order)
result = client.get_with_metadata('key', skip_lru_bump: true)

# Combined with thundering herd protection
result = client.get_with_metadata('key', vivify_ttl: 30, recache_ttl: 60)
```

**Files:**
- `lib/dalli/client.rb`
- `lib/dalli/protocol/meta.rb`

### 6. Thundering Herd Protection (`fetch_with_lock`)
**Reference:** Shopify/dalli#46

New method that uses meta protocol's `N` and `R` flags:

```ruby
# New API - prevents multiple clients from regenerating same cache entry
client.fetch_with_lock(key, ttl: 300, lock_ttl: 30) do
  expensive_database_query
end
```

**Files:**
- `lib/dalli/client.rb`
- `lib/dalli/protocol/meta.rb`

---

## v4.2.0 - Performance & Observability ✅ COMPLETE

### 6. Buffered I/O Improvements ✅
**Reference:** Shopify/dalli#55, Shopify/dalli#38

Implemented:
- Set `socket.sync = false` to enable buffered I/O
- Added explicit `flush` calls before reading responses
- Reduces syscalls for pipelined operations (100-300% improvement for multi ops)

**Files modified:**
- `lib/dalli/protocol/connection_manager.rb` - Added `flush` method and `sync = false`
- `lib/dalli/protocol/meta.rb` - Added flush calls before response reading
- `lib/dalli/protocol/binary.rb` - Added flush calls before response reading

### 7. OpenTelemetry Tracing Support ✅
**Reference:** Shopify/dalli#56

Implemented lightweight distributed tracing that auto-detects OpenTelemetry SDK:

```ruby
# Automatically instruments when OTel is present
# Zero overhead when OTel is not loaded
client = Dalli::Client.new('localhost:11211')
```

**Features:**
- Traces `get`, `set`, `delete`, `get_multi`, `set_multi`, `delete_multi`, `get_with_metadata`, `fetch_with_lock`
- Spans include `db.system: memcached` and `db.operation` attributes
- Single-key operations include `server.address` attribute
- Multi-key operations include `db.memcached.key_count`, `hit_count`, `miss_count`
- Exceptions are automatically recorded on spans with error status

**Files created/modified:**
- `lib/dalli/instrumentation.rb` - New lightweight tracing module
- `lib/dalli/client.rb` - Added tracing to all operations
- `test/test_instrumentation.rb` - Unit tests for instrumentation

### 8. get_multi Optimizations ✅
**Reference:** Shopify/dalli#44, Shopify/dalli#45

Implemented:
- Use `Set` instead of `Array` for deleted server tracking (O(1) vs O(n) lookups)
- Use `select!(&:connected?)` instead of `delete_if { |s| !s.connected? }`
- Skip bitflags request in raw mode (saves 2 bytes/request, skips parsing)

**Files modified:**
- `lib/dalli/pipelined_getter.rb`
- `lib/dalli/protocol/meta/request_formatter.rb`
- `lib/dalli/protocol/meta.rb`
- `lib/dalli/protocol/base.rb`

---

## Future Performance Work (From Shopify PRs)

These optimizations from Shopify's fork were not included in the v4.2.0 scope but could provide additional performance benefits. They are documented here for potential future work.

### Allocation Reduction in Response Processor
**Reference:** Shopify/dalli#45

The `read_data()` method in `response_processor.rb` creates allocations on every call. Shopify's PR achieved ~56% allocation reduction through:

| Optimization | Status | Benefit |
|-------------|--------|---------|
| Reuse terminator buffer in `read_data()` | ❌ Not done | Fewer allocations per get |
| Pre-size buffers | ❌ Not done | Fewer reallocations |

**Implementation notes:**
- Requires careful refactoring of the response processor
- Most impactful in tight loops (get_multi with many keys)
- Should benchmark before/after to validate gains

### Single-Server Raw Mode Fast Path
**Reference:** Shopify/dalli#45

For the common case of a single memcached server with raw mode enabled, a simplified code path could avoid overhead from multi-server handling.

**Implementation notes:**
- Detect single-server + raw mode configuration
- Skip server grouping and ring lookups when only one server
- Estimated 10-20% improvement for this specific use case

---

## v4.3.0 - Bug Fixes & Quality

### 9. GitHub Issues to Address

| Issue | Description | Priority | Status |
|-------|-------------|----------|--------|
| #1034 | struct timeval architecture-dependent packing | High | Likely Fixed |
| #776/#941 | get_multi hangs with large key counts | Medium | Needs Design |
| #1022 | Empty string with `cache_nils: false` + `raw: true` | Medium | Needs Rails Input |
| #1019 | Make NAMESPACE_SEPARATOR configurable | Low | Easy Fix |
| #805 | Migration path for instrument_errors | Low | Likely Resolved |
| #1039 | "No request in progress" after Ruby 3.4.2 | Low | Insufficient Info |

#### Issue #1034: struct timeval Architecture-Dependent Packing

**Status:** Likely already fixed by PR #1025

**Background:** The `struct timeval` used for `SO_RCVTIMEO`/`SO_SNDTIMEO` socket options has architecture-dependent sizes. The previous code used `'l_2'` pack format which doesn't work on all architectures (e.g., 64-bit time_t with 32-bit long on ARM).

**Current State:** PR #1025 (merged in v4.0.0) changed timeout handling to use Ruby 3.0+'s `IO#timeout=` when available, falling back to `setsockopt` only on older Ruby versions. Since Ruby 3.0+ is the common case now, most users won't hit this.

**Remaining Work:**
- Verify if the fallback path (Ruby < 3.0) still needs fixing
- Consider adopting @lnussbaum's patch for the fallback path which detects the correct format via `getsockopt`:
  ```ruby
  timeval_formats = ['q l_', 'l l_', 'q l_ x4']
  expected_length = sock.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO).data.length
  timeval_format = timeval_formats.find { |fmt| [0, 0].pack(fmt).length == expected_length }
  ```
- Alternatively, drop support for Ruby < 3.0 in v5.0 and remove the fallback entirely

#### Issue #776 / #941: get_multi Hangs with Large Key Counts

**Status:** Needs design work - these are duplicates of the same underlying issue

**Background:** When `get_multi` is called with a large number of keys (60k+), the operation hangs. This occurs because:
1. Dalli sends all `getkq` (quiet get) requests before reading responses
2. Memcached doesn't actually wait for the final `noop` before responding - it buffers responses and sends them once an internal buffer fills
3. If Dalli's send buffer fills before all requests are sent, and memcached's response buffer fills, both sides deadlock waiting on each other

**Workaround:** Users can increase `sndbuf` and `rcvbuf` socket options, or batch keys externally (e.g., 500k key batches).

**Proposed Solution (from @petergoldstein in #776):**
Interleave reading and writing for large key sets:
1. Group keys by server
2. For each server:
   a. Break keys into chunks (e.g., 10k)
   b. After each chunk, call read on ResponseBuffer to drain socket
   c. Send noop after all chunks
   d. Process remaining results
3. Wait on sockets for incomplete servers

**Considerations:**
- Only affects large key sets - small operations unchanged
- Timeout handling becomes more complex with batching
- Ring abstraction may need adjustment for per-server batching
- Binary protocol is deprecated, so focus implementation on meta protocol only

#### Issue #1022: Empty String with `cache_nils: false` + `raw: true`

**Status:** Needs Rails team input before implementing

**Background:** When storing `nil` with `raw: true`, Dalli converts it to an empty string `""`. This is problematic because:
- `cache_nils: true` + `raw: true` → stores `""`, returns `""` (not `nil`)
- `cache_nils: false` + `raw: true` → stores `""`, returns `""` (should error or not cache)

**Proposed Behavior (from @nickamorim):**
- `raw: true` + `cache_nils: true` → Store a sentinel value, return `nil` on get
- `raw: true` + `cache_nils: false` → Raise `ArgumentError`

**Alternative (from @grcooper):**
- `raw: true` should only accept strings - any non-string (including `nil`) should raise `ArgumentError`
- This is a stricter interpretation: raw mode means "I know what I'm doing with strings"

**Blocked On:** Need @byroot's input on Rails MemCacheStore behavior:
- Does Rails pass `nil` values to Dalli with `raw: true`?
- What does `StringMarshaller` do with `nil`?
- What behavior does Rails expect?

**Action:** Comment on issue requesting Rails team clarification before implementing.

#### Issue #1019: Make NAMESPACE_SEPARATOR Configurable

**Status:** Low priority, easy fix

**Background:** The namespace separator is hardcoded as `:`. Some users want to customize this.

**Implementation:**
- Add `namespace_separator` option to client
- Default to `:` for backwards compatibility
- Validate that separator contains only allowed characters (alphanumeric, common punctuation)
- Must not contain characters that would break memcached protocol (spaces, newlines, etc.)

**Allowed Characters:** Should match memcached key restrictions - printable ASCII except space and control characters. Recommend restricting to: `A-Za-z0-9_\-:.`

#### Issue #805: Migration Path for instrument_errors

**Status:** Likely resolved by OpenTelemetry support

**Background:** The old `DalliStore` (removed in favor of Rails' `MemCacheStore`) had an `instrument_errors` parameter that generated `ActiveSupport::Notifications` events on errors.

**Current State:**
- Dalli 4.2.0 now has OpenTelemetry support with automatic error recording on spans
- Rails 8.0+ improved error handling in `MemCacheStore` - errors are now rescued and reported to `Rails.error`
- The combination of OTel spans + Rails.error may provide equivalent or better observability

**Action:**
- Document the migration path in README: use OpenTelemetry for error visibility
- Verify Rails 8.0+ `MemCacheStore` error handling is sufficient
- Close issue with documentation update if OTel + Rails.error covers the use case

#### Issue #1039: "No request in progress" after Ruby 3.4.2

**Status:** Insufficient information, no other reports

**Background:** Single user report of "No request in progress" error after upgrading to Ruby 3.4.2. No reproduction steps or additional context provided.

**Current State:** @petergoldstein asked for more information; no response from reporter. No other users have reported this issue.

**Action:** Keep issue open but deprioritize. If more reports come in or reporter responds with details, investigate then.

### 10. Testing & CI Improvements
- Add TruffleRuby to CI (#988)
- Increase test coverage for meta protocol edge cases
- Add benchmarks to CI (from Shopify's work)

---

## v5.0.0 - Breaking Changes

### 11. Remove Binary Protocol
**Reference:** Shopify/dalli#13

**Delete files:**
- `lib/dalli/protocol/binary.rb`
- `lib/dalli/protocol/binary/` (entire directory)
- Related test files

**Modify:**
- `lib/dalli/client.rb` - Remove protocol selection logic
- `lib/dalli.rb` - Remove binary requires
- Flatten `lib/dalli/protocol/meta/` to `lib/dalli/protocol/`

### 12. Remove SASL Authentication
Meta protocol doesn't support authentication. Users requiring auth should:
- Use network-level security (VPN, firewall rules)
- Use memcached's TLS support
- Stay on Dalli 4.x with binary protocol

### 13. Update Minimum Requirements
- Ruby 3.2+ (following Ruby EOL policy)
- memcached 1.6+ (meta protocol minimum)
- Remove JRuby-specific code paths

### 14. Simplify Codebase Structure

**Current structure:**
```
lib/dalli/protocol/
├── base.rb
├── binary.rb
├── binary/
│   ├── request_formatter.rb
│   ├── response_header.rb
│   ├── response_processor.rb
│   └── sasl_authentication.rb
├── meta.rb
├── meta/
│   ├── key_regularizer.rb
│   ├── request_formatter.rb
│   └── response_processor.rb
├── connection_manager.rb
├── server_config_parser.rb
├── ttl_sanitizer.rb
├── value_compressor.rb
├── value_marshaller.rb
└── value_serializer.rb
```

**v5.0 structure (after binary removal):**
```
lib/dalli/protocol/
├── base.rb
├── key_regularizer.rb
├── request_formatter.rb
├── response_processor.rb
├── connection_manager.rb
├── server_config_parser.rb
├── ttl_sanitizer.rb
├── value_compressor.rb
├── value_marshaller.rb
└── value_serializer.rb
```

---

## Meta Protocol Flags: Current vs Planned Support

### mg (get) Flags
| Flag | Current | v4.1+ | Description |
|------|---------|-------|-------------|
| `v` | ✅ | ✅ | Return value |
| `f` | ✅ | ✅ | Return bitflags |
| `c` | ✅ | ✅ | Return CAS |
| `b` | ✅ | ✅ | Base64 key |
| `T` | ✅ | ✅ | Touch TTL |
| `k` | ✅ | ✅ | Return key |
| `q` | ✅ | ✅ | Quiet mode |
| `s` | ✅ | ✅ | Return size |
| `h` | ❌ | ✅ | Hit status |
| `l` | ❌ | ✅ | Last access time |
| `u` | ❌ | ✅ | Skip LRU bump |
| `N` | ❌ | ✅ | Vivify on miss |
| `R` | ❌ | ✅ | Recache threshold |

### ms (set) Flags
| Flag | Current | v4.1+ | Description |
|------|---------|-------|-------------|
| `c` | ✅ | ✅ | Return CAS |
| `b` | ✅ | ✅ | Base64 key |
| `F` | ✅ | ✅ | Set bitflags |
| `C` | ✅ | ✅ | Compare CAS |
| `T` | ✅ | ✅ | Set TTL |
| `M` | ✅ | ✅ | Mode (S/E/R/A/P) |
| `q` | ✅ | ✅ | Quiet mode |
| `I` | ❌ | ✅ | Mark invalid |

### md (delete) Flags
| Flag | Current | v4.1+ | Description |
|------|---------|-------|-------------|
| `b` | ✅ | ✅ | Base64 key |
| `C` | ✅ | ✅ | Compare CAS |
| `q` | ✅ | ✅ | Quiet mode |
| `I` | ❌ | ✅ | Mark stale |
| `x` | ❌ | ✅ | Remove value only |

---

## Implementation Priority

### Phase 1: v4.1.0 (High Impact) ✅ COMPLETE
1. ✅ Binary protocol deprecation warnings
2. ✅ `set_multi` implementation
3. ✅ `delete_multi` implementation
4. ✅ Thundering herd flags (N, R, W, X, Z)
5. ✅ `fetch_with_lock` method
6. ✅ Metadata flags (h, l, u)
7. ✅ `get_with_metadata` method

### Phase 2: v4.2.0 (Performance) ✅ COMPLETE
6. ✅ Buffered I/O improvements
7. ✅ OpenTelemetry support (with enhanced span attributes)
8. ✅ get_multi optimizations (Set, select!, raw mode skip_flags)

### Phase 3: v4.3.0 (Polish)
9. Bug fixes from GitHub issues
10. CI/testing improvements

### Phase 4: v5.0.0 (Cleanup)
11. Remove binary protocol
12. Remove SASL auth
13. Update minimum requirements
14. Simplify codebase structure

---

## Key Shopify PRs to Reference

| PR | Status | Feature | Dalli Status |
|----|--------|---------|--------------|
| #59 | Open | delete_multi | ✅ Done in v4.1.0 |
| #46 | Open | fetch_with_lock (thundering herd) | ✅ Done in v4.1.0 |
| #56 | Merged | OpenTelemetry tracing | ✅ Done in v4.2.0 (enhanced) |
| #55 | Merged | Buffered I/O | ✅ Done in v4.2.0 |
| #45 | Open | get_multi optimizations | ⚠️ Partial (see Future Work) |
| #44 | Merged | Raw mode optimizations | ✅ Done in v4.2.0 |
| #13 | Reference | Binary protocol removal | 📋 Planned for v5.0 |
| #11 | Reference | Non-blocking I/O | 📋 Low priority |

---

## Verification

After implementing each phase:
1. Run `bundle exec rubocop` - must pass
2. Run `bundle exec rake` - all tests must pass
3. Run benchmarks to verify no performance regression
4. Test against memcached 1.6.x (meta protocol)
5. For v4.x: Also test against memcached 1.4.x/1.5.x (binary protocol)
