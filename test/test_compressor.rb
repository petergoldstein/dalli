# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli::Compressor' do
  it 'compresses data using Zlib::Deflate' do
    assert_equal "x\x9CKLJN\x01\x00\x03\xD8\x01\x8B".b,
                 Dalli::Compressor.compress('abcd')
    assert_equal "x\x9C+\xC9HU(,\xCDL\xCEVH*\xCA/\xCFSH\xCB\xAFP\xC8*\xCD-(\x06\x00z\x06\t\x83".b,
                 Dalli::Compressor.compress('the quick brown fox jumps')
  end

  it 'deccompresses data using Zlib::Deflate' do
    assert_equal('abcd', Dalli::Compressor.decompress("x\x9CKLJN\x01\x00\x03\xD8\x01\x8B"))
    assert_equal('the quick brown fox jumps',
                 Dalli::Compressor.decompress(
                   "x\x9C+\xC9HU(,\xCDL\xCEVH*\xCA/\xCFSH\xCB\xAFP\xC8*\xCD-(\x06\x00z\x06\t\x83"
                 ))
  end
end

# Decompressing with max_bytes stops as soon as the output passes the limit,
# so a small compressed value can't expand into gigabytes of memory.
[Dalli::Compressor, Dalli::GzipCompressor].each do |compressor|
  describe "#{compressor}.decompress with max_bytes" do
    let(:data) { 'abc' * 100_000 }
    let(:compressed) { compressor.compress(data) }

    it 'returns values within the limit unchanged' do
      assert_equal data.b, compressor.decompress(compressed, max_bytes: data.bytesize).b
    end

    it 'raises UnmarshalError for values that decompress past the limit' do
      error = assert_raises(Dalli::UnmarshalError) { compressor.decompress(compressed, max_bytes: 1024) }

      assert_match(/exceeds 1024 bytes/, error.message)
    end

    it 'stops a decompression bomb without inflating it fully' do
      bomb = compressor.compress("\0" * (16 * 1024 * 1024))

      assert_raises(Dalli::UnmarshalError) { compressor.decompress(bomb, max_bytes: 1024 * 1024) }
    end

    # Bytes after the end of the compressed stream aren't part of the value,
    # whichever path inflates it
    it 'ignores data after the end of the stream, as without max_bytes' do
      ["#{compressed}TRAILER", compressed + compressed, compressed + ('x' * 200_000)].each do |input|
        assert_equal compressor.decompress(input).b, compressor.decompress(input, max_bytes: 10_000_000).b
      end
    end

    # A signal can make Ruby's zlib return before the stream is done
    # (ruby/zlib#49). It shows on Linux, where the signal interrupts the
    # thread that is compressing.
    it 'round-trips values while signals interrupt zlib' do
      skip 'needs MRI signal handling' unless RUBY_ENGINE == 'ruby'

      values = [Random.new(1).bytes(1024 * 1024), "\0" * (4 * 1024 * 1024), 'abc' * 100_000]
      received = while_signaled do
        10.times do
          values.each do |value|
            assert_equal value.b, compressor.decompress(compressor.compress(value), max_bytes: value.bytesize).b
            assert_equal value.b, compressor.decompress(compressor.compress(value)).b
          end
        end
      end

      assert_operator received, :>, 0
    end

    # Runs the block while another thread sends this process USR2, and returns
    # how many signals arrived
    def while_signaled
      received = 0
      previous = Signal.trap('USR2') { received += 1 }
      signaler = Thread.new do
        loop do
          Process.kill('USR2', Process.pid)
          sleep 0.0002
        end
      end
      yield
      received
    ensure
      signaler&.kill&.join
      Signal.trap('USR2', previous)
    end

    it 'has no limit without max_bytes' do
      assert_equal data.b, compressor.decompress(compressed).b
    end

    it 'inflates a value whose compressed form spans many input slices' do
      # Random bytes barely compress, so this is several slices long
      mixed = Random.new(42).bytes(300_000) + ('xyz' * 100_000)
      packed = compressor.compress(mixed)

      assert_operator packed.bytesize, :>, 4 * Dalli::Compressor::INFLATE_SLICE_BYTES
      assert_equal mixed.b, compressor.decompress(packed, max_bytes: mixed.bytesize).b
      assert_raises(Dalli::UnmarshalError) { compressor.decompress(packed, max_bytes: mixed.bytesize - 1) }
    end
  end
end
