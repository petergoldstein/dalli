# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dalli is a high-performance pure Ruby client for accessing memcached servers. It supports failover, SSL/TLS, and thread-safe operation. Requires memcached 1.6+ (meta protocol).

## Common Commands

```bash
# Install dependencies
bundle install

# Run all tests (requires memcached installed locally)
bundle exec rake

# Run a single test file
bundle exec ruby -Itest test/integration/test_operations.rb

# Run a specific test by name
bundle exec ruby -Itest test/integration/test_operations.rb -n test_get_set

# Run benchmarks
bundle exec rake bench

# Lint code
bundle exec rubocop

# Auto-fix lint issues
bundle exec rubocop -a
```

## Architecture

### Core Components

**Dalli::Client** (`lib/dalli/client.rb`) - Main entry point. Handles key validation, server selection via the ring, and retries on network errors. All memcached operations flow through the `perform` method.

**Dalli::Ring** (`lib/dalli/ring.rb`) - Implements consistent hashing for distributing keys across multiple servers. Uses CRC32 hashing and a configurable number of points per server (160 by default). Handles failover by trying alternate hash positions when a server is down.

**Protocol Layer** (`lib/dalli/protocol/`) - Uses the memcached meta protocol (requires memcached 1.6+). `Protocol::Meta` inherits from `Protocol::Base` which contains common connection management, pipelining, and value marshalling logic.

**Value Pipeline** - Values flow through three stages:
1. `ValueSerializer` - Serializes Ruby objects (default: Marshal)
2. `ValueCompressor` - Compresses large values (default: Zlib, 4KB threshold)
3. `ValueMarshaller` - Coordinates serialization and compression, manages bitflags

**Connection Management** (`lib/dalli/protocol/connection_manager.rb`) - Handles socket lifecycle, reconnection logic, and timeout handling. Supports both TCP and UNIX domain sockets.

**Rack::Session::Dalli** (`lib/rack/session/dalli.rb`) - Rack session middleware using memcached for storage. Supports connection pooling via the `connection_pool` gem.

### Threading Model

By default, Dalli wraps each server connection with mutex locks (`Dalli::Threadsafe` module). For connection pool usage, threadsafe mode can be disabled per-client.

### Test Infrastructure

Tests require a local memcached 1.6+ installation. The `MemcachedManager` (`test/utils/memcached_manager.rb`) spawns memcached instances on random ports for test isolation.

SSL tests use self-signed certificates generated at runtime via `CertificateGenerator`.

## Development Workflow

**After any code changes, you MUST verify:**

1. **Run Rubocop** - `bundle exec rubocop` must pass with no offenses
2. **Run Tests** - `bundle exec rake` must pass with no failures

Do not consider a change complete until both checks pass. If either fails, fix the issues before finishing.
