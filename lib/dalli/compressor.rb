# frozen_string_literal: true

require 'zlib'
require 'stringio'

module Dalli
  ##
  # Default compressor used by Dalli, that uses
  # Zlib DEFLATE to compress data.
  ##
  class Compressor
    def self.compress(data)
      Zlib::Deflate.deflate(data)
    end

    # max_bytes caps the decompressed size; inflating stops and raises as soon
    # as the output passes it, so a small compressed value can't expand into
    # gigabytes of memory.
    def self.decompress(data, max_bytes: nil)
      return Zlib::Inflate.inflate(data) unless max_bytes

      inflate_within_limit(Zlib::Inflate.new, data, max_bytes)
    end

    def self.inflate_within_limit(inflater, data, max_bytes)
      out = String.new(encoding: Encoding::BINARY)
      inflater.inflate(data) { |chunk| append_within_limit(out, chunk, max_bytes) }
      append_within_limit(out, inflater.finish, max_bytes)
    ensure
      inflater.close
    end

    def self.append_within_limit(out, chunk, max_bytes)
      out << chunk if chunk
      return out if out.bytesize <= max_bytes

      raise Dalli::UnmarshalError, "Decompressed value exceeds #{max_bytes} bytes (decompressed_max_bytes)"
    end
  end

  ##
  # Alternate compressor for Dalli, that uses
  # Gzip.  Gzip adds a checksum to each compressed
  # entry.
  ##
  class GzipCompressor
    def self.compress(data)
      io = StringIO.new(+'', 'w')
      gz = Zlib::GzipWriter.new(io)
      gz.write(data)
      gz.close
      io.string
    end

    def self.decompress(data, max_bytes: nil)
      return Zlib::GzipReader.new(StringIO.new(data, 'rb')).read unless max_bytes

      # MAX_WBITS + 16 makes zlib read the gzip format (and check its CRC)
      Compressor.inflate_within_limit(Zlib::Inflate.new(Zlib::MAX_WBITS + 16), data, max_bytes)
    end
  end
end
