# frozen_string_literal: true

module Dalli
  ##
  # Instrumentation support for Dalli. Provides hooks for distributed tracing
  # via OpenTelemetry when the SDK is available.
  #
  # When OpenTelemetry is loaded, Dalli automatically creates spans for cache operations.
  # When OpenTelemetry is not available, all tracing methods are no-ops with zero overhead.
  #
  # Dalli 4.3.2 uses the stable OTel semantic conventions for database spans.
  #
  # == Span Attributes
  #
  # All spans include the following default attributes:
  # - +db.system.name+ - Always "memcached"
  #
  # Single-key operations (+get+, +set+, +delete+, +incr+, +decr+, etc.) add:
  # - +db.operation.name+ - The operation name (e.g., "get", "set")
  # - +server.address+ - The server hostname (e.g., "localhost")
  # - +server.port+ - The server port as an integer (e.g., 11211); omitted for Unix sockets
  #
  # Multi-key operations (+get_multi+) add:
  # - +db.operation.name+ - "get_multi"
  # - +db.memcached.key_count+ - Number of keys requested
  # - +db.memcached.hit_count+ - Number of keys found in cache
  # - +db.memcached.miss_count+ - Number of keys not found
  #
  # Bulk write operations (+set_multi+, +delete_multi+) add:
  # - +db.operation.name+ - The operation name
  # - +db.memcached.key_count+ - Number of keys in the operation
  #
  # == Optional Attributes
  #
  # - +db.query.text+ - The operation and key(s), controlled by the +:otel_db_statement+ client option:
  #   - +:include+ - Full text (e.g., "get mykey")
  #   - +:obfuscate+ - Obfuscated (e.g., "get ?")
  #   - +nil+ (default) - Attribute omitted
  # - +peer.service+ - Logical service name, set via the +:otel_peer_service+ client option
  #
  # == Error Handling
  #
  # When an exception occurs during a traced operation:
  # - The exception is recorded on the span via +record_exception+
  # - The span status is set to error with the exception message
  # - The exception is re-raised to the caller
  #
  # @example Checking if tracing is enabled
  #   Dalli::Instrumentation.enabled? # => true if OpenTelemetry is loaded
  #
  ##
  module Instrumentation
    # Default attributes included on all memcached spans.
    # @return [Hash] frozen hash with 'db.system.name' => 'memcached'
    DEFAULT_ATTRIBUTES = { 'db.system.name' => 'memcached' }.freeze

    class << self
      # Returns the OpenTelemetry tracer if available, nil otherwise.
      #
      # The tracer is cached after first lookup for performance.
      # Uses the library name 'dalli' and current Dalli::VERSION.
      #
      # @return [OpenTelemetry::Trace::Tracer, nil] the tracer or nil if OTel unavailable
      def tracer
        return @tracer if defined?(@tracer)

        @tracer = (OpenTelemetry.tracer_provider.tracer('dalli', Dalli::VERSION) if defined?(OpenTelemetry))
      end

      # Returns true if instrumentation is enabled (OpenTelemetry SDK is available).
      #
      # @return [Boolean] true if tracing is active, false otherwise
      def enabled?
        !tracer.nil?
      end

      # Wraps a block with a span if instrumentation is enabled.
      #
      # Creates a client span with the given name and attributes merged with
      # DEFAULT_ATTRIBUTES. The block is executed within the span context.
      # If an exception occurs, it is recorded on the span before re-raising.
      #
      # When tracing is disabled (OpenTelemetry not loaded), this method
      # simply yields directly with zero overhead.
      #
      # @param name [String] the span name (e.g., 'get', 'set', 'delete')
      # @param attributes [Hash] span attributes to merge with defaults.
      #   Common attributes include:
      #   - 'db.operation.name' - the operation name
      #   - 'server.address' - the server hostname
      #   - 'server.port' - the server port (integer)
      #   - 'db.memcached.key_count' - number of keys (for multi operations)
      # @yield the cache operation to trace
      # @return [Object] the result of the block
      # @raise [StandardError] re-raises any exception from the block
      #
      # @example Tracing a set operation
      #   trace('set', { 'db.operation.name' => 'set', 'server.address' => 'localhost', 'server.port' => 11211 }) do
      #     server.set(key, value, ttl)
      #   end
      #
      def trace(name, attributes = {})
        return yield unless enabled?

        tracer.in_span(name, attributes: DEFAULT_ATTRIBUTES.merge(attributes), kind: :client) do |_span|
          yield
        end
      end

      # Like trace, but yields the span to allow adding attributes after execution.
      #
      # This is useful for operations where metrics are only known after the
      # operation completes, such as get_multi where hit/miss counts depend
      # on the cache response.
      #
      # When tracing is disabled, yields nil as the span argument.
      #
      # @param name [String] the span name (e.g., 'get_multi')
      # @param attributes [Hash] initial span attributes to merge with defaults
      # @yield [OpenTelemetry::Trace::Span, nil] the span object, or nil if disabled
      # @return [Object] the result of the block
      # @raise [StandardError] re-raises any exception from the block
      #
      # @example Recording hit/miss metrics after get_multi
      #   trace_with_result('get_multi', { 'db.operation.name' => 'get_multi' }) do |span|
      #     results = fetch_from_cache(keys)
      #     if span
      #       span.set_attribute('db.memcached.hit_count', results.size)
      #       span.set_attribute('db.memcached.miss_count', keys.size - results.size)
      #     end
      #     results
      #   end
      #
      def trace_with_result(name, attributes = {}, &)
        return yield(nil) unless enabled?

        tracer.in_span(name, attributes: DEFAULT_ATTRIBUTES.merge(attributes), kind: :client, &)
      end
    end
  end
end
