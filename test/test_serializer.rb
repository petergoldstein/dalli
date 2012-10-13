# encoding: utf-8
require 'helper'
require 'memcached_mock'

describe 'Serializer' do

  should 'default to Marshal' do
    assert_equal Marshal, Dalli.serializer
  end

  should 'support a custom serializer' do
    original_serializer = Dalli.serializer
    begin
      Dalli.serializer = JSON

      memcached do |dc|
        assert dc.set("json_test", {"foo" => "bar"})
        json = dc.get("json_test", :raw => true)
        p json
        obj = JSON.parse(json)
        assert_equal({"foo" => "bar"})
      end
    ensure
      Dalli.serializer = original_serializer
    end
  end
end
