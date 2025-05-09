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

      attr_accessor :serialization_options

      def initialize(protocol_options)
        @serialization_options =
          DEFAULTS.merge(protocol_options.select { |k, _| OPTIONS.include?(k) })
      end

      def store(value, req_options, bitflags)
        if req_options
          return [value.to_s, bitflags] if req_options[:raw]

          # If the value is a simple string, going through serialization is costly
          # for no benefit other than preserving encoding.
          # Assuming most strings are either UTF-8 or BINARY we can just store
          # that information in the bitflags.
          if req_options[:string_fastpath] && value.instance_of?(String)
            case value.encoding
            when Encoding::BINARY
              return [value, bitflags]
            when Encoding::UTF_8
              return [value, bitflags | FLAG_UTF8]
            end
          end
        end

        [serialize_value(value), bitflags | FLAG_SERIALIZED]
      end

      def retrieve(value, bitflags)
        serialized = (bitflags & FLAG_SERIALIZED) != 0
        if serialized
          begin
            serializer.load(value)
          rescue StandardError
            raise UnmarshalError, 'Unable to unmarshal value'
          end
        elsif (bitflags & FLAG_UTF8) != 0
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
    end
  end
end
