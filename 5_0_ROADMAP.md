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

## v4.2.0 - Performance & Observability

### 6. Buffered I/O Improvements
**Reference:** Shopify/dalli#55, Shopify/dalli#38

- Use Ruby's native non-blocking I/O (available since Ruby 3.x)
- Remove custom `readfull` implementation
- Optimize buffer handling for multi-operations

**Files:**
- `lib/dalli/protocol/connection_manager.rb`
- `lib/dalli/socket.rb`

### 7. OpenTelemetry Tracing Support
**Reference:** Shopify/dalli#56

Add optional distributed tracing:

```ruby
# Gemfile
gem 'opentelemetry-sdk'

# Usage - automatically instruments when OTel is present
client = Dalli::Client.new('localhost:11211')
```

**Files to create:**
- `lib/dalli/opentelemetry_middleware.rb`
- `lib/dalli/middlewares.rb`

### 8. get_multi Optimizations
**Reference:** Shopify/dalli#44, Shopify/dalli#45

- Reduce allocations in hot paths
- Optimize for raw mode usage
- Pre-size buffers where possible

---

## v4.3.0 - Bug Fixes & Quality

### 9. GitHub Issues to Address

| Issue | Description | Priority |
|-------|-------------|----------|
| #1039 | "No request in progress" after Ruby 3.4.2 | High |
| #1034 | struct timeval architecture-dependent packing | Medium |
| #1022 | Empty string with `cache_nils: false` + `raw: true` | Medium |
| #1019 | Make NAMESPACE_SEPARATOR configurable | Low |
| #941 | Hanging on read_multi with large key counts | Medium |
| #776 | send_multiget hangs with >1.7MB of keys | Medium |

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

### Phase 2: v4.2.0 (Performance)
6. Buffered I/O improvements
7. OpenTelemetry support
8. get_multi optimizations

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

| PR | Status | Feature | Priority |
|----|--------|---------|----------|
| #59 | Open | delete_multi | High |
| #46 | Open | fetch_with_lock (thundering herd) | High |
| #56 | Merged | OpenTelemetry tracing | Medium |
| #55 | Merged | Buffered I/O | Medium |
| #45 | Open | get_multi optimizations | Medium |
| #44 | Merged | Raw mode optimizations | Done (in 4.0.1) |
| #13 | Reference | Binary protocol removal | v5.0 |
| #11 | Reference | Non-blocking I/O | Medium |

---

## Verification

After implementing each phase:
1. Run `bundle exec rubocop` - must pass
2. Run `bundle exec rake` - all tests must pass
3. Run benchmarks to verify no performance regression
4. Test against memcached 1.6.x (meta protocol)
5. For v4.x: Also test against memcached 1.4.x/1.5.x (binary protocol)
