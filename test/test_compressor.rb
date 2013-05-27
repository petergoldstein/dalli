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

  it 'default to Dalli::Compressor' do
    memcached_kill(29199) do |dc|
      memcache = Dalli::Client.new('127.0.0.1:29199')
      memcache.set 1,2
      assert_equal Dalli::Compressor, memcache.instance_variable_get('@ring').servers.first.compressor
    end
  end

  it 'support a custom compressor' do
    memcached_kill(29199) do |dc|
      memcache = Dalli::Client.new('127.0.0.1:29199', :compressor => NoopCompressor)
      memcache.set 1,2
      begin
        assert_equal NoopCompressor, memcache.instance_variable_get('@ring').servers.first.compressor

        memcached(19127) do |newdc|
          assert newdc.set("string-test", "a test string")
          assert_equal("a test string", newdc.get("string-test"))
        end
      end
    end
  end
end

describe 'GzipCompressor' do

  it 'compress and uncompress data using Zlib::GzipWriter/Reader' do
    memcached(19127,nil,{:compress=>true,:compressor=>Dalli::GzipCompressor}) do |dc|
      data = (0...1025).map{65.+(rand(26)).chr}.join
      assert dc.set("test", data)
      assert_equal Dalli::GzipCompressor, dc.instance_variable_get('@ring').servers.first.compressor
      assert_equal(data, dc.get("test"))
    end
  end

end
