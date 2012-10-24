# encoding: utf-8
require 'helper'
require 'json'
require 'memcached_mock'

describe 'Serializer' do

  should 'default to Marshal' do
    assert_equal Marshal, Dalli.serializer
  end

  should 'support a custom serializer' do
    original_serializer = Dalli.serializer
    begin
      Dalli.serializer = JSON
      assert_equal JSON, Dalli.serializer

      memcached(19128) do |dc|
        assert dc.set("json_test", {"foo" => "bar"})
        assert_equal({"foo" => "bar"}, dc.get("json_test"))
      end
    ensure
      Dalli.serializer = original_serializer
    end
  end
end
