Dalli [![Tests](https://github.com/petergoldstein/dalli/actions/workflows/tests.yml/badge.svg)](https://github.com/petergoldstein/dalli/actions/workflows/tests.yml)
=====

Dalli is a high performance pure Ruby client for accessing memcached servers.

Dalli supports:

* Simple and complex memcached configurations
* Failover between memcached instances
* Fine-grained control of data serialization and compression
* Thread-safe operation (either through use of a connection pool, or by using the Dalli client in threadsafe mode)
* SSL/TLS connections to memcached
* OpenTelemetry distributed tracing (automatic when SDK is present)

The name is a variant of Salvador Dali for his famous painting [The Persistence of Memory](http://en.wikipedia.org/wiki/The_Persistence_of_Memory).

## Requirements

* Ruby 3.3 or later (JRuby also supported)
* memcached 1.6.27 or later

Dalli is tested against both the minimum supported memcached version and the
latest release. Earlier 1.6.x servers are not supported: the meta protocol
rejects unknown flags outright, so features added after a server's release fail
with `CLIENT_ERROR invalid flag` rather than degrading.

### Known Ruby issue: crash on an interrupted socket read

Dalli sets socket timeouts with `IO#timeout`. Ruby 3.3.0–3.3.7 and 3.4.0–3.4.2 have a bug ([Ruby #21195](https://bugs.ruby-lang.org/issues/21195)) where a timed read interrupted by a signal aborts the whole process:

```
[BUG] rb_sys_fail_path_in(io_fillbuf, fd:N ) - errno == 0
```

The crash is inside Ruby itself, so it can't be rescued. It's fixed in Ruby 3.3.8 and 3.4.3. If you see this crash, upgrade to one of those versions or later.

## Configuration Options

### Namespace

Use namespaces to partition your cache and avoid key collisions between different applications or environments:

```ruby
# All keys will be prefixed with "myapp:"
Dalli::Client.new('localhost:11211', namespace: 'myapp')

# Dynamic namespace using a Proc (evaluated on each operation)
Dalli::Client.new('localhost:11211', namespace: -> { "tenant:#{Thread.current[:tenant_id]}" })
```

### Namespace Separator

By default, the namespace and key are joined with a colon (`:`). You can customize this with the `namespace_separator` option:

```ruby
# Keys will be prefixed with "myapp/" instead of "myapp:"
Dalli::Client.new('localhost:11211', namespace: 'myapp', namespace_separator: '/')
```

The separator must be a single non-alphanumeric character. Valid examples: `:`, `/`, `|`, `.`, `-`, `_`, `#`

### Maximum Item Size

memcached rejects items larger than its `-I` setting (1MB by default). Set `value_max_bytes` to the same value if you change it:

```ruby
# memcached started with -I 2m
Dalli::Client.new('localhost:11211', value_max_bytes: 2 * 1024 * 1024)
```

memcached's limit covers the whole item, so Dalli checks the stored (serialized and compressed) value plus the key plus 63 bytes of per-item overhead against `value_max_bytes`, and raises `Dalli::ValueOverMaxSize` before sending anything larger. With the defaults, the largest value you can store under a 10-byte key is 1,048,576 - 10 - 63 = 1,048,503 bytes.

### Deferred Draining

By default, a `quiet` (or `multi`) block ends by waiting for the replies memcached still sends for its quiet requests, one round trip for each server the block wrote to. With `defer_drain: true`, the block returns without waiting:

```ruby
dc = Dalli::Client.new('localhost:11211', defer_drain: true)

dc.quiet { dc.set('key', 'value') } # returns without a round trip
dc.get('key')                       # first drains that connection with a noop, then gets the value
```

The requests are still sent right away. Their replies stay unread on the connection until the next non-quiet request to that server, which reads them first with one `noop`. Error replies to quiet requests are discarded either way. With `defer_drain` they're discarded at that later point instead of at the end of the block.

**Replies accumulate until a non-quiet request drains them.** memcached still replies to some quiet requests: `NF` for a quiet `delete`, `incr` or `decr` of a missing key, `NS` for an `add` or `replace` that didn't store, and error replies. Those replies wait on the socket. A client that mixes quiet writes with reads (or other non-quiet requests) to the same servers drains them as it goes, and needs nothing more.

A client that only ever makes quiet requests, such as a worker that only issues quiet deletes, never sends that next request. Its unread replies keep growing, and if they fill the connection's socket buffers, the connection can stall until a socket timeout closes it and Dalli reconnects. Workloads like that should call `drain_deferred_responses` periodically, for example after each batch or job:

```ruby
jobs.each do |job|
  job.keys.each { |key| dc.quiet { dc.delete(key) } }
  dc.drain_deferred_responses # reads and discards the replies waiting on each server
end
```

`drain_deferred_responses` only sends a `noop` to servers that were sent quiet requests since they were last drained, so calling it when nothing is pending costs nothing.

## Security Note

By default, Dalli uses Ruby's Marshal for serialization. Deserializing untrusted data with Marshal can lead to remote code execution. If you cache user-controlled data, consider using a safer serializer:

```ruby
Dalli::Client.new('localhost:11211', serializer: Dalli::JSONSerializer)
```

`Dalli::JSONSerializer` reads values with `JSON.parse`, so it only ever returns plain hashes, arrays, strings, numbers, booleans and `nil`. Passing the `JSON` module itself (`serializer: JSON`) reads values with `JSON.load`, which can create objects of other classes from a stored `json_class` key and is not recommended for data an attacker might write.

Per-request `raw: true` returns the stored bytes without deserializing or decompressing them, on every read method (`get`, `get_multi`, `get_cas`, `get_with_metadata` and `fetch`).

### Long keys

memcached limits keys to 250 bytes. Dalli shortens a longer key (counting its namespace) to the start of the key, followed by `:md5:` and a hex digest of the whole key:

```ruby
dc.set("report:#{'x' * 300}", 'data')
# stored under "report:xxx...xxx:md5:<32 hex characters>"
```

The shortened key is an ordinary memcached key, so a short key written in exactly that form names the same item, and reading or writing it reads or overwrites the long key's value. This only matters if untrusted input can choose an entire cache key. If it can, hash the untrusted part yourself so the key never needs shortening, or reject keys that contain `:md5:`.

The digest is MD5 by default. `digest_class:` takes any object that responds to `hexdigest`, such as `Digest::SHA256`. Changing it renames every shortened key, so existing entries for long keys are missed once.

See the [5.0-Upgrade.md](5.0-Upgrade.md) guide for upgrade information.

## OpenTelemetry Tracing

Dalli automatically instruments operations with [OpenTelemetry](https://opentelemetry.io/) when the SDK is present. No configuration is required - just add the OpenTelemetry gems to your application:

```ruby
# Gemfile
gem 'opentelemetry-sdk'
gem 'opentelemetry-exporter-otlp' # or your preferred exporter
```

When OpenTelemetry is loaded, Dalli creates spans for:
- Single key operations: `get`, `set`, `delete`, `add`, `replace`, `incr`, `decr`, etc.
- Multi-key operations: `get_multi`, `set_multi`, `delete_multi`
- Advanced operations: `get_with_metadata`, `fetch_with_lock`

### Span Attributes

All spans include:
- `db.system`: `memcached`
- `db.operation`: The operation name (e.g., `get`, `set_multi`)

Single-key operations also include:
- `server.address`: The memcached server that handled the request (e.g., `localhost:11211`)

Multi-key operations include cache efficiency metrics:
- `db.memcached.key_count`: Number of keys in the request
- `db.memcached.hit_count`: Number of keys found (for `get_multi`)
- `db.memcached.miss_count`: Number of keys not found (for `get_multi`)

### Error Handling

Exceptions are automatically recorded on spans with error status. When an operation fails:
1. The exception is recorded on the span via `span.record_exception(e)`
2. The span status is set to error with the exception message
3. The exception is re-raised to the caller

### Disabling Instrumentation

To disable instrumentation at runtime (e.g., in tests or specific environments):

```ruby
Dalli::Instrumentation.disable!
```

You can also assign a custom tracer directly:

```ruby
Dalli::Instrumentation.tracer = my_custom_tracer
```

### Zero Overhead

When OpenTelemetry is not present, there is zero overhead - the tracing code checks once at startup and bypasses all instrumentation logic entirely when the SDK is not loaded.

![Persistence of Memory](https://upload.wikimedia.org/wikipedia/en/d/dd/The_Persistence_of_Memory.jpg)


## Documentation and Information

* [User Documentation](https://github.com/petergoldstein/dalli/wiki) - The documentation is maintained in the repository's wiki.  
* [Announcements](https://github.com/petergoldstein/dalli/discussions/categories/announcements) - Announcements of interest to the Dalli community will be posted here.
* [Bug Reports](https://github.com/petergoldstein/dalli/issues) - If you discover a problem with Dalli, please submit a bug report in the tracker.
* [Forum](https://github.com/petergoldstein/dalli/discussions/categories/q-a) - If you have questions about Dalli, please post them here.
* [Client API](https://www.rubydoc.info/gems/dalli) - Ruby documentation for the `Dalli::Client` API

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute, including our policy on AI-authored contributions.

## Appreciation

Dalli would not exist in its current form without the contributions of many people.  But special thanks go to several individuals and organizations:

* Mike Perham - for originally authoring the Dalli project and serving as maintainer and primary contributor for many years
* Eric Wong - for help using his [kgio](http://bogomips.org/kgio/) library.
* Brian Mitchell - for his remix-stash project which was helpful when implementing and testing the binary protocol support.
* [CouchBase](http://couchbase.com) - for their sponsorship of the original development


## Authors

* [Peter M. Goldstein](https://github.com/petergoldstein) - current maintainer
* [Mike Perham](https://github.com/mperham) and contributors


## Copyright

Copyright (c) Mike Perham, Peter M. Goldstein. See LICENSE for details.
