# frozen_string_literal: true

require_relative '../helper'
require 'json'

describe 'Serializer configuration' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'defaults to Marshal' do
        memcached(p, find_available_port) do |dc|
          dc.set 1, 2

          assert_equal Marshal, dc.instance_variable_get(:@ring).servers.first.serializer
        end
      end

      it 'supports a custom serializer' do
        memcached(p, find_available_port) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", serializer: JSON)
          memcache.set 1, 2
          begin
            assert_equal JSON, memcache.instance_variable_get(:@ring).servers.first.serializer

            memcached(p, find_available_port) do |newdc|
              assert newdc.set('json_test', { 'foo' => 'bar' })
              assert_equal({ 'foo' => 'bar' }, newdc.get('json_test'))
            end
          end
        end
      end
    end
  end
end
