# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli::Compressor' do
  it 'compresses data using Zlib::Deflate' do
    assert_equal "x\x9CKLJN\x01\x00\x03\xD8\x01\x8B".b,
                 ::Dalli::Compressor.compress('abcd')
    assert_equal "x\x9C+\xC9HU(,\xCDL\xCEVH*\xCA/\xCFSH\xCB\xAFP\xC8*\xCD-(\x06\x00z\x06\t\x83".b,
                 ::Dalli::Compressor.compress('the quick brown fox jumps')
  end

  it 'deccompresses data using Zlib::Deflate' do
    assert_equal('abcd', ::Dalli::Compressor.decompress("x\x9CKLJN\x01\x00\x03\xD8\x01\x8B"))
    assert_equal('the quick brown fox jumps',
                 ::Dalli::Compressor.decompress(
                   "x\x9C+\xC9HU(,\xCDL\xCEVH*\xCA/\xCFSH\xCB\xAFP\xC8*\xCD-(\x06\x00z\x06\t\x83"
                 ))
  end
end
