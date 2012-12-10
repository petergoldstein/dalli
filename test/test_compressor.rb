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
    memcache = Dalli::Client.new('127.0.0.1:11211')
    memcache.set 1,2
    assert_equal Dalli::Compressor, memcache.instance_variable_get('@ring').servers.first.compressor
  end

  should 'support a custom compressor' do
    memcache = Dalli::Client.new('127.0.0.1:11211', :compressor => NoopCompressor)
    memcache.set 1,2
    begin
      assert_equal NoopCompressor, memcache.instance_variable_get('@ring').servers.first.compressor

      memcached(19127) do |dc|
        assert dc.set("string-test", "a test string")
        assert_equal("a test string", dc.get("string-test"))
      end
    end
  end
end

describe 'GzipCompressor' do

  should 'compress and uncompress data using Zlib::GzipWriter/Reader' do
    memcached(19127,nil,{:compress=>true,:compressor=>Dalli::GzipCompressor}) do |dc|
      data = (0...1025).map{65.+(rand(26)).chr}.join
      assert dc.set("test", data)
      assert_equal Dalli::GzipCompressor, dc.instance_variable_get('@ring').servers.first.compressor
      assert_equal(data, dc.get("test"))
    end
  end

end
