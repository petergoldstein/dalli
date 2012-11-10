# encoding: utf-8
require 'helper'
require 'json'
require 'memcached_mock'

describe 'Serializer' do

  should 'default to Marshal' do
    memcache = Dalli::Client.new('127.0.0.1:11211')
    memcache.set 1,2
    assert_equal Marshal, memcache.instance_variable_get('@ring').servers.first.serializer
  end

  should 'support a custom serializer' do
    memcache = Dalli::Client.new('127.0.0.1:11211', :serializer => JSON)
    memcache.set 1,2
    begin
      assert_equal JSON, memcache.instance_variable_get('@ring').servers.first.serializer

      memcached(19128) do |dc|
        assert dc.set("json_test", {"foo" => "bar"})
        assert_equal({"foo" => "bar"}, dc.get("json_test"))
      end
    end
  end
end
