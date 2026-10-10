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
        # max memcached item size in bytes: value + key + ITEM_OVERHEAD_BYTES. Set it to
        # memcached's -I value (default 1 MB).
        value_max_bytes: 1024 * 1024
      }.freeze

      OPTIONS = DEFAULTS.keys.freeze

      # memcached's -I limit applies to the whole item, not just the value. On
      # 64-bit memcached 1.6 an item takes the value, the key, and 63 bytes of
      # overhead: a 48-byte header, 8 bytes of CAS, 4 bytes of client flags,
      # the key's NUL terminator and the value's trailing CRLF. (Measured
      # against memcached 1.6.45 with -I 512k, 1m, 2m and 5m; an item stored
      # with zero flags or with CAS disabled needs a few bytes less.)
      ITEM_OVERHEAD_BYTES = 63

      def self.error_if_over_max_value_bytes(key, value, value_max_bytes)
        item_bytes = value.bytesize + key.bytesize + ITEM_OVERHEAD_BYTES
        return if item_bytes <= value_max_bytes

        message = "Value for #{key} over max size: #{value_max_bytes} <= #{item_bytes} " \
                  "(#{value.bytesize} value bytes + #{key.bytesize} key bytes + #{ITEM_OVERHEAD_BYTES} item overhead)"
        raise Dalli::ValueOverMaxSize, message
      end

      def_delegators :@value_serializer, :serializer
      def_delegators :@value_compressor, :compressor, :compression_min_size, :compress_by_default?

      def initialize(client_options)
        @value_serializer = ValueSerializer.new(client_options)
        @value_compressor = ValueCompressor.new(client_options)

        @marshal_options =
          DEFAULTS.merge(client_options.slice(*OPTIONS))
        @marshal_options[:value_max_bytes] = @marshal_options[:value_max_bytes].to_i
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
        self.class.error_if_over_max_value_bytes(key, value, value_max_bytes)
      end
    end
  end
end
