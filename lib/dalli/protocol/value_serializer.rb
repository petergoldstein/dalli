# frozen_string_literal: true

module Dalli
  module Protocol
    ##
    # Dalli::Protocol::ValueSerializer compartmentalizes the logic for managing
    # serialization and deserialization of stored values.  It manages interpreting
    # relevant options from both client and request, determining whether to
    # serialize/deserialize on store/retrieve, and processes bitflags as necessary.
    ##
    class ValueSerializer
      DEFAULTS = {
        serializer: Marshal
      }.freeze

      OPTIONS = DEFAULTS.keys.freeze

      # https://www.hjp.at/zettel/m/memcached_flags.rxml
      # Looks like most clients use bit 0 to indicate native language serialization
      FLAG_SERIALIZED = 0x1
      FLAG_UTF8 = 0x2

      # Class variable to track whether the Marshal warning has been logged
      @@marshal_warning_logged = false # rubocop:disable Style/ClassVars

      attr_accessor :serialization_options

      def initialize(protocol_options)
        @serialization_options =
          DEFAULTS.merge(protocol_options.slice(*OPTIONS))
        warn_if_marshal_default(protocol_options) unless protocol_options[:silence_marshal_warning]
      end

      def store(value, req_options, bitflags)
        return store_raw(value, bitflags) if req_options&.dig(:raw)
        return store_string_fastpath(value, bitflags) if use_string_fastpath?(value, req_options)

        [serialize_value(value), bitflags | FLAG_SERIALIZED]
      end

      def retrieve(value, bitflags)
        serialized = bitflags.anybits?(FLAG_SERIALIZED)
        if serialized
          begin
            serializer.load(value)
          rescue StandardError
            raise UnmarshalError, 'Unable to unmarshal value'
          end
        elsif bitflags.anybits?(FLAG_UTF8)
          value.force_encoding(Encoding::UTF_8)
        else
          value
        end
      end

      def serializer
        @serialization_options[:serializer]
      end

      def serialize_value(value)
        serializer.dump(value)
      rescue Timeout::Error => e
        raise e
      rescue StandardError => e
        # Serializing can throw several different types of generic Ruby exceptions.
        # Convert to a specific exception so we can special case it higher up the stack.
        exc = Dalli::MarshalError.new(e.message)
        exc.set_backtrace e.backtrace
        raise exc
      end

      private

      def store_raw(value, bitflags)
        unless value.is_a?(String)
          raise Dalli::MarshalError, "Dalli raw mode requires string values, got: #{value.class}"
        end

        [value, bitflags]
      end

      # If the value is a simple string, going through serialization is costly
      # for no benefit other than preserving encoding.
      # Assuming most strings are either UTF-8 or BINARY we can just store
      # that information in the bitflags.
      def store_string_fastpath(value, bitflags)
        case value.encoding
        when Encoding::BINARY then [value, bitflags]
        when Encoding::UTF_8 then [value, bitflags | FLAG_UTF8]
        else [serialize_value(value), bitflags | FLAG_SERIALIZED]
        end
      end

      def use_string_fastpath?(value, req_options)
        req_options&.dig(:string_fastpath) && value.instance_of?(String)
      end

      def warn_if_marshal_default(protocol_options)
        return if protocol_options.key?(:serializer)
        return if @@marshal_warning_logged

        Dalli.logger.warn 'SECURITY WARNING: Dalli is using Marshal for serialization. ' \
                          'Marshal can execute arbitrary code during deserialization. ' \
                          'If your memcached server could be compromised, consider using ' \
                          'a safer serializer like JSON: Dalli::Client.new(servers, serializer: JSON)'
        @@marshal_warning_logged = true # rubocop:disable Style/ClassVars
      end
    end
  end
end
