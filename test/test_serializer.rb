# encoding: utf-8
# frozen_string_literal: true
require_relative 'helper'
require 'json'

describe 'Serializer' do
  it 'default to Marshal' do
    memcached(29198) do |dc|
      dc.set 1,2
      assert_equal Marshal, dc.instance_variable_get('@ring').servers.first.serializer
    end
  end

  it 'support a custom serializer' do
    memcached(29198) do |dc, port|
      memcache = Dalli::Client.new("127.0.0.1:#{port}", :serializer => JSON)
      memcache.set 1,2
      begin
        assert_equal JSON, memcache.instance_variable_get('@ring').servers.first.serializer

        memcached(21956) do |newdc|
          assert newdc.set("json_test", {"foo" => "bar"})
          assert_equal({"foo" => "bar"}, newdc.get("json_test"))
        end
      end
    end
  end
end
