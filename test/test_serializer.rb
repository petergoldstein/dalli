# encoding: utf-8
require 'helper'
require 'json'
require 'memcached_mock'

describe 'Serializer' do

  it 'default to Marshal' do
    memcached_kill(29198) do |dc|
      memcache = Dalli::Client.new('127.0.0.1:29198')
      memcache.set 1,2
      assert_equal Marshal, memcache.instance_variable_get('@ring').servers.first.serializer
    end
  end

  it 'support a custom serializer' do
    memcached_kill(29198) do |dc|
      memcache = Dalli::Client.new('127.0.0.1:29198', :serializer => JSON)
      memcache.set 1,2
      begin
        assert_equal JSON, memcache.instance_variable_get('@ring').servers.first.serializer

        memcached(19128) do |newdc|
          assert newdc.set("json_test", {"foo" => "bar"})
          assert_equal({"foo" => "bar"}, newdc.get("json_test"))
        end
      end
    end
  end
end
