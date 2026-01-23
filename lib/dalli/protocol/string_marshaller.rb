# frozen_string_literal: true

module Dalli
  module Protocol
    ##
    # Dalli::Protocol::ValueMarshaller compartmentalizes the logic for marshalling
    # and unmarshalling unstructured data (values) to Memcached.  It also enforces
    # limits on the maximum size of marshalled data.
    ##
    class StringMarshaller
      DEFAULT_MAX_BYTES = 1024 * 1024
      DEFAULTS = {
        # max size of value in bytes (default is 1 MB, can be overriden with "memcached -I <size>")
        value_max_bytes: 1024 * 1024
      }.freeze

      OPTIONS = DEFAULTS.keys.freeze

      attr_reader :value_max_bytes

      def initialize(client_options)
        @value_max_bytes = client_options.fetch(:value_max_bytes) do
          ValueMarshaller::DEFAULTS.fetch(:value_max_bytes)
        end.to_i
      end

      def store(key, value, _options = nil)
        raise MarshalError, "Dalli in :raw mode only support strings, got: #{value.class}" unless value.is_a?(String)

        error_if_over_max_value_bytes(key, value)
        [value, 0]
      end

      def retrieve(value, _flags)
        value
      end

      def error_if_over_max_value_bytes(key, value)
        return if value.bytesize <= value_max_bytes

        message = "Value for #{key} over max size: #{value_max_bytes} <= #{value.bytesize}"
        raise Dalli::ValueOverMaxSize, message
      end
    end
  end
end
