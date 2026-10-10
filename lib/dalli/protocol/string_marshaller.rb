# frozen_string_literal: true

module Dalli
  module Protocol
    ##
    # Dalli::Protocol::StringMarshaller is a pass-through marshaller for use with
    # the :raw client option. It bypasses serialization and compression entirely,
    # expecting values to already be strings (e.g., pre-serialized by Rails'
    # ActiveSupport::Cache). It still enforces the maximum value size limit.
    ##
    class StringMarshaller
      DEFAULTS = {
        # max memcached item size in bytes: value + key + ITEM_OVERHEAD_BYTES. Set it to
        # memcached's -I value (default 1 MB).
        value_max_bytes: 1024 * 1024
      }.freeze

      attr_reader :value_max_bytes

      def initialize(client_options)
        @value_max_bytes = client_options.fetch(:value_max_bytes) do
          DEFAULTS.fetch(:value_max_bytes)
        end.to_i
      end

      def store(key, value, _options = nil)
        raise MarshalError, "Dalli in :raw mode only supports strings, got: #{value.class}" unless value.is_a?(String)

        error_if_over_max_value_bytes(key, value)
        [value, 0]
      end

      def retrieve(value, _flags)
        value
      end

      # Interface compatibility methods - these return nil since
      # StringMarshaller bypasses serialization and compression entirely.

      def serializer
        nil
      end

      def compressor
        nil
      end

      def compression_min_size
        nil
      end

      def compress_by_default?
        false
      end

      private

      def error_if_over_max_value_bytes(key, value)
        ValueMarshaller.error_if_over_max_value_bytes(key, value, value_max_bytes)
      end
    end
  end
end
