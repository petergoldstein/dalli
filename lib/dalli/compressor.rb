# frozen_string_literal: true

require 'zlib'

module Dalli
  ##
  # Default compressor used by Dalli, that uses
  # Zlib DEFLATE to compress data.
  ##
  class Compressor
    def self.compress(data)
      deflate_fully(Zlib::Deflate.new, data)
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
      return inflate_fully(Zlib::Inflate.new, data) unless may_exceed?(data, max_bytes)

      inflate_within_limit(Zlib::Inflate.new, data, max_bytes)
    end

    # Ruby's zlib extension can return from a call before zlib has finished
    # when a signal interrupts it (ruby/zlib#49). One-shot calls like
    # Zlib::Deflate.deflate then raise or, with zlib 3.2.4, return truncated
    # output, so these call finish until the stream has ended.
    def self.deflate_fully(deflater, data)
      finish_stream(deflater, deflater.deflate(data, Zlib::FINISH))
    ensure
      deflater.close
    end

    def self.inflate_fully(inflater, data)
      finish_stream(inflater, inflater.inflate(data))
    ensure
      inflater.close
    end

    def self.finish_stream(stream, out)
      out << next_chunk(stream) until stream.finished?
      out
    end

    # Each finish makes progress, so one that returns nothing means the
    # stream can't end: the compressed input is truncated
    def self.next_chunk(stream)
      chunk = stream.finish
      raise Zlib::BufError, 'buffer error' if chunk.empty?

      chunk
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
        # Anything after the end of the stream isn't part of the value, as
        # with Zlib::Inflate.inflate; finish would return it as output
        break if inflater.finished?
      end
      append_within_limit(out, next_chunk(inflater), max_bytes) until inflater.finished?
      out
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
    # MAX_WBITS + 16 makes zlib write and read the gzip format (and check its CRC)
    WINDOW_BITS = Zlib::MAX_WBITS + 16

    def self.compress(data)
      Compressor.deflate_fully(Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, WINDOW_BITS), data)
    end

    def self.decompress(data, max_bytes: nil)
      inflater = Zlib::Inflate.new(WINDOW_BITS)
      return Compressor.inflate_fully(inflater, data) unless Compressor.may_exceed?(data, max_bytes)

      Compressor.inflate_within_limit(inflater, data, max_bytes)
    end
  end
end
