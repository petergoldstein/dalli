# frozen_string_literal: true

require 'forwardable'

module Dalli
  module Protocol
    ##
    # Dalli::Protocol::ValueMarshaller compartmentalizes the logic for marshalling
    # and unmarshalling unstructured data (values) to Memcached.  It also enforces
    # limits on the maximum size of marshalled data.
    ##
    class ValueMarshaller
      extend Forwardable

      DEFAULTS = {
        # max size of value in bytes (default is 1 MB, can be overriden with "memcached -I <size>")
        value_max_bytes: 1024 * 1024
      }.freeze

      OPTIONS = DEFAULTS.keys.freeze

      def_delegators :@value_serializer, :serializer
      def_delegators :@value_compressor, :compressor, :compression_min_size, :compress_by_default?

      def initialize(client_options)
        @value_serializer = ValueSerializer.new(client_options)
        @value_compressor = ValueCompressor.new(client_options)

        @marshal_options =
          DEFAULTS.merge(client_options.select { |k, _| OPTIONS.include?(k) })
      end

      def store(key, value, options = nil)
        bitflags = 0
        value, bitflags = @value_serializer.store(value, options, bitflags)
        value, bitflags = @value_compressor.store(value, options, bitflags)

        error_if_over_max_value_bytes(key, value)
        [value, bitflags]
      end

      def retrieve(value, flags)
        value = @value_compressor.retrieve(value, flags)
        @value_serializer.retrieve(value, flags)
      end

      def value_max_bytes
        @marshal_options[:value_max_bytes]
      end

      def error_if_over_max_value_bytes(key, value)
        return if value.bytesize <= value_max_bytes

        message = "Value for #{key} over max size: #{value_max_bytes} <= #{value.bytesize}"
        raise Dalli::ValueOverMaxSize, message
      end
    end
  end
end
