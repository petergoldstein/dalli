# frozen_string_literal: true

require 'English'

module Dalli
  module Protocol
    ##
    # Dalli::Protocol::ValueCompressor compartmentalizes the logic for managing
    # compression and decompression of stored values.  It manages interpreting
    # relevant options from both client and request, determining whether to
    # compress/decompress on store/retrieve, and processes bitflags as necessary.
    ##
    class ValueCompressor
      DEFAULTS = {
        compress: true,
        compressor: ::Dalli::Compressor,
        # min byte size to attempt compression
        compression_min_size: 4 * 1024, # 4K
        # max size a stored value may decompress to (nil: no limit). Guards
        # against a small compressed value expanding into gigabytes on read.
        decompressed_max_bytes: 128 * 1024 * 1024 # 128 MiB
      }.freeze

      OPTIONS = DEFAULTS.keys.freeze

      KEYWORD_PARAMETER_TYPES = %i[key keyreq].freeze
      private_constant :KEYWORD_PARAMETER_TYPES

      # https://www.hjp.at/zettel/m/memcached_flags.rxml
      # Looks like most clients use bit 1 to indicate gzip compression.
      FLAG_COMPRESSED = 0x2

      def initialize(client_options)
        @compression_options =
          DEFAULTS.merge(client_options.slice(*OPTIONS))
      end

      def store(value, req_options, bitflags)
        do_compress = compress_value?(value, req_options)
        store_value = do_compress ? compressor.compress(value) : value
        bitflags |= FLAG_COMPRESSED if do_compress

        [store_value, bitflags]
      end

      def retrieve(value, bitflags)
        return value unless bitflags.anybits?(FLAG_COMPRESSED)

        max_bytes = @compression_options[:decompressed_max_bytes]
        # Custom compressors that only define decompress(data) keep working,
        # without the limit
        if max_bytes && compressor_accepts_max_bytes?
          compressor.decompress(value, max_bytes: max_bytes)
        else
          compressor.decompress(value)
        end

      # TODO: We likely want to move this rescue into the Dalli::Compressor / Dalli::GzipCompressor
      # itself, since not all compressors necessarily use Zlib.  For now keep it here, so the behavior
      # of custom compressors doesn't change.
      rescue Zlib::Error
        raise UnmarshalError, "Unable to uncompress value: #{$ERROR_INFO.message}"
      end

      def compressor_accepts_max_bytes?
        return @compressor_accepts_max_bytes if defined?(@compressor_accepts_max_bytes)

        @compressor_accepts_max_bytes =
          begin
            compressor.method(:decompress).parameters.any? do |type, name|
              name == :max_bytes && KEYWORD_PARAMETER_TYPES.include?(type)
            end
          rescue NameError # an object without a reflectable decompress method
            false
          end
      end

      def compress_by_default?
        @compression_options[:compress]
      end

      def compressor
        @compression_options[:compressor]
      end

      def compression_min_size
        @compression_options[:compression_min_size]
      end

      # Checks whether we should apply compression when serializing a value
      # based on the specified options.  Returns false unless the value
      # is greater than the minimum compression size.  Otherwise returns
      # based on a method-level option if specified, falling back to the
      # server default.
      def compress_value?(value, req_options)
        return false unless value.bytesize >= compression_min_size
        return compress_by_default? unless req_options && !req_options[:compress].nil?

        req_options[:compress]
      end
    end
  end
end
