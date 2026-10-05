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

    # DEFLATE can't expand data by more than about 1032:1
    MAX_EXPANSION = 1032
    # Compressed input is fed to zlib this many bytes at a time. MRI's zlib
    # yields the output in small chunks; one that returns it instead still
    # produces at most MAX_EXPANSION times this per step.
    INFLATE_SLICE_BYTES = 64 * 1024

    # max_bytes caps the decompressed size; inflating stops and raises as soon
    # as the output passes it, so a small compressed value can't expand into
    # gigabytes of memory.
    def self.decompress(data, max_bytes: nil)
      return Zlib::Inflate.inflate(data) unless may_exceed?(data, max_bytes)

      inflate_within_limit(Zlib::Inflate.new, data, max_bytes)
    end

    # False when even the largest possible expansion stays within max_bytes,
    # so the value can be inflated in one step
    def self.may_exceed?(data, max_bytes)
      max_bytes ? data.bytesize * MAX_EXPANSION > max_bytes : false
    end

    def self.inflate_within_limit(inflater, data, max_bytes)
      out = String.new(encoding: Encoding::BINARY)
      0.step(data.bytesize - 1, INFLATE_SLICE_BYTES) do |pos|
        inflate_slice(inflater, data.byteslice(pos, INFLATE_SLICE_BYTES), out, max_bytes)
      end
      append_within_limit(out, inflater.finish, max_bytes)
    ensure
      inflater.close
    end

    # Both yielded and returned output count toward the limit
    def self.inflate_slice(inflater, slice, out, max_bytes)
      rest = inflater.inflate(slice) { |chunk| append_within_limit(out, chunk, max_bytes) }
      append_within_limit(out, rest, max_bytes)
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
      return Zlib::GzipReader.new(StringIO.new(data, 'rb')).read unless Compressor.may_exceed?(data, max_bytes)

      # MAX_WBITS + 16 makes zlib read the gzip format (and check its CRC)
      Compressor.inflate_within_limit(Zlib::Inflate.new(Zlib::MAX_WBITS + 16), data, max_bytes)
    end
  end
end
