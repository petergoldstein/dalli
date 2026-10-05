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
