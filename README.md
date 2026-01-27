Dalli [![Tests](https://github.com/petergoldstein/dalli/actions/workflows/tests.yml/badge.svg)](https://github.com/petergoldstein/dalli/actions/workflows/tests.yml)
=====

Dalli is a high performance pure Ruby client for accessing memcached servers.

Dalli supports:

* Simple and complex memcached configurations
* Failover between memcached instances
* Fine-grained control of data serialization and compression
* Thread-safe operation (either through use of a connection pool, or by using the Dalli client in threadsafe mode)
* SSL/TLS connections to memcached
* SASL authentication
* OpenTelemetry distributed tracing (automatic when SDK is present)

The name is a variant of Salvador Dali for his famous painting [The Persistence of Memory](http://en.wikipedia.org/wiki/The_Persistence_of_Memory).

## Requirements

* Ruby 3.1 or later
* memcached 1.4 or later (1.6+ recommended for meta protocol support)

## Protocol Options

Dalli supports two protocols for communicating with memcached:

* `:binary` (default) - Works with all memcached versions, supports SASL authentication
* `:meta` - Requires memcached 1.6+, better performance for some operations, no authentication support

```ruby
Dalli::Client.new('localhost:11211', protocol: :meta)
```

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

## Security Note

By default, Dalli uses Ruby's Marshal for serialization. Deserializing untrusted data with Marshal can lead to remote code execution. If you cache user-controlled data, consider using a safer serializer:

```ruby
Dalli::Client.new('localhost:11211', serializer: JSON)
```

See the [4.0-Upgrade.md](4.0-Upgrade.md) guide for more information.

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

If you have a fix you wish to provide, please fork the code, fix in your local project and then send a pull request on github.  Please ensure that you include a test which verifies your fix and update the [changelog](CHANGELOG.md) with a one sentence description of your fix so you get credit as a contributor.

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
