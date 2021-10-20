# frozen_string_literal: true

require_relative "helper"
require "json"

class NoopCompressor
  def self.compress(data)
    data
  end

  def self.decompress(data)
    data
  end
end

describe "Compressor" do
  it "default to Dalli::Compressor" do
    memcached(29199) do |dc|
      dc.set 1, 2
      assert_equal Dalli::Compressor, dc.instance_variable_get("@ring").servers.first.instance_variable_get("@value_compressor").compressor
    end
  end

  it "support a custom compressor" do
    memcached(29199) do |dc|
      memcache = Dalli::Client.new("127.0.0.1:29199", compressor: NoopCompressor)
      memcache.set 1, 2
      begin
        assert_equal NoopCompressor, memcache.instance_variable_get("@ring").servers.first.instance_variable_get("@value_compressor").compressor

        memcached(19127) do |newdc|
          assert newdc.set("string-test", "a test string")
          assert_equal("a test string", newdc.get("string-test"))
        end
      end
    end
  end
end

describe "GzipCompressor" do
  it "compress and uncompress data using Zlib::GzipWriter/Reader" do
    memcached(19127, nil, {compress: true, compressor: Dalli::GzipCompressor}) do |dc|
      data = (0...1025).map { rand(65..90).chr }.join
      assert dc.set("test", data)
      assert_equal(data, dc.get("test"))
      assert_equal Dalli::GzipCompressor, dc.instance_variable_get("@ring").servers.first.instance_variable_get("@value_compressor").compressor
    end
  end
end
