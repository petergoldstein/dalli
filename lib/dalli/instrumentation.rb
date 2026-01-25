# frozen_string_literal: true

module Dalli
  ##
  # Instrumentation support for Dalli. Provides hooks for distributed tracing
  # via OpenTelemetry when the SDK is available.
  ##
  module Instrumentation
    # Default attributes for all memcached spans
    DEFAULT_ATTRIBUTES = { 'db.system' => 'memcached' }.freeze

    class << self
      # Returns the OpenTelemetry tracer if available, nil otherwise
      def tracer
        return @tracer if defined?(@tracer)

        @tracer = (OpenTelemetry.tracer_provider.tracer('dalli', Dalli::VERSION) if defined?(OpenTelemetry))
      end

      # Returns true if instrumentation is enabled (OpenTelemetry is available)
      def enabled?
        !tracer.nil?
      end

      # Wraps a block with a span if instrumentation is enabled.
      # Returns the block result regardless of whether tracing is enabled.
      #
      # @param name [String] the span name (e.g., 'get', 'set', 'get_multi')
      # @param attributes [Hash] additional span attributes
      # @yield the operation to trace
      # @return the result of the block
      def trace(name, attributes = {}, &)
        return yield unless enabled?

        tracer.in_span(name, attributes: DEFAULT_ATTRIBUTES.merge(attributes), kind: :client, &)
      end
    end
  end
end
