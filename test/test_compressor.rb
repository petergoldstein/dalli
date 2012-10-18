# encoding: utf-8
require 'helper'
require 'json'
require 'memcached_mock'

class NoopCompressor
  def self.compress(data)
    data
  end

  def self.decompress(data)
    data
  end
end

describe 'Compressor' do

  should 'default to Dalli::Compressor' do
    assert_equal Dalli::Compressor, Dalli.compressor
  end

  should 'support a custom compressor' do
    original_compressor = Dalli.compressor
    begin
      Dalli.compressor = NoopCompressor
      assert_equal NoopCompressor, Dalli.compressor

      memcached(19127) do |dc|
        assert dc.set("string-test", "a test string")
        assert_equal("a test string", dc.get("string-test"))
      end
    ensure
      Dalli.compressor = original_compressor
    end
  end
end
