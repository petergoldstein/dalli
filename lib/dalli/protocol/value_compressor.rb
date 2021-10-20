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
        compression_min_size: 4 * 1024 # 4K
      }.freeze

      OPTIONS = DEFAULTS.keys.freeze

      # https://www.hjp.at/zettel/m/memcached_flags.rxml
      # Looks like most clients use bit 1 to indicate gzip compression.
      FLAG_COMPRESSED = 0x2

      def initialize(client_options)
        # Support the deprecated compression option, but don't allow it to override
        # an explicit compress
        # Remove this with 4.0
        if client_options.key?(:compression) && !client_options.key?(:compress)
          Dalli.logger.warn "DEPRECATED: Dalli's :compression option is now just 'compress: true'.  " \
                            'Please update your configuration.'
          client_options[:compress] = client_options.delete(:compression)
        end

        @compression_options =
          DEFAULTS.merge(client_options.select { |k, _| OPTIONS.include?(k) })
      end

      def store(value, req_options, bitflags)
        do_compress = compress_value?(value, req_options)
        store_value = do_compress ? compressor.compress(value) : value
        bitflags |= FLAG_COMPRESSED if do_compress

        [store_value, bitflags]
      end

      def retrieve(value, bitflags)
        compressed = (bitflags & FLAG_COMPRESSED) != 0
        compressed ? compressor.decompress(value) : value

      # TODO: We likely want to move this rescue into the Dalli::Compressor / Dalli::GzipCompressor
      # itself, since not all compressors necessarily use Zlib.  For now keep it here, so the behavior
      # of custom compressors doesn't change.
      rescue Zlib::Error
        raise UnmarshalError, "Unable to uncompress value: #{$ERROR_INFO.message}"
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
