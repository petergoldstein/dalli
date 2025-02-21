# frozen_string_literal: true

require_relative '../helper'
require 'json'

describe 'Serializer configuration' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'defaults to Marshal' do
        memcached(p, port_or_socket: 29_198) do |dc|
          dc.set 1, 2

          assert_equal Marshal, dc.instance_variable_get(:@ring).servers.first.serializer
        end
      end

      it 'skips the serializer for simple strings when string_fastpath is enabled' do
        memcached(p, port_or_socket: 29_198) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", string_fastpath: true)
          string = 'héllø'
          memcache.set 'utf-8', string

          assert_equal string, memcache.get('utf-8')
          assert_equal Encoding::UTF_8, memcache.get('utf-8').encoding

          binary = "\0\xff".b
          memcache.set 'binary', binary

          assert_equal binary, memcache.get('binary')
          assert_equal Encoding::BINARY, memcache.get('binary').encoding

          latin1 = string.encode(Encoding::ISO_8859_1)
          memcache.set 'latin1', latin1

          assert_equal latin1, memcache.get('latin1')
          assert_equal Encoding::ISO_8859_1, memcache.get('latin1').encoding

          # Ensure strings that went through the fastpath are properly retreived
          # by clients without string_fastpath enabled.
          memcache = Dalli::Client.new("127.0.0.1:#{port}", string_fastpath: false)

          assert_equal string, memcache.get('utf-8')
          assert_equal Encoding::UTF_8, memcache.get('utf-8').encoding
          assert_equal binary, memcache.get('binary')
          assert_equal Encoding::BINARY, memcache.get('binary').encoding
          assert_equal latin1, memcache.get('latin1')
          assert_equal Encoding::ISO_8859_1, memcache.get('latin1').encoding
        end
      end

      it 'supports a custom serializer' do
        memcached(p, port_or_socket: 29_198) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", serializer: JSON)
          memcache.set 1, 2
          begin
            assert_equal JSON, memcache.instance_variable_get(:@ring).servers.first.serializer

            memcached(p, port_or_socket: 21_956) do |newdc|
              assert newdc.set('json_test', { 'foo' => 'bar' })
              assert_equal({ 'foo' => 'bar' }, newdc.get('json_test'))
            end
          end
        end
      end

      it 'supports no serialization' do
        memcached(p, port_or_socket: 29_198) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", raw: true)

          with_nil_logger do
            error = assert_raises(Dalli::MarshalError) do
              memcache.set '1', 2
            end
            assert_match 'Integer', error.message
          end

          memcache.set '1', '2'

          memcached(p, port_or_socket: 21_956, cli_args: '', client_options: { raw: true }) do |newdc|
            assert newdc.set('json_test', 'json_test_value')

            value = newdc.get('json_test')

            assert_equal('json_test_value', value)
            assert_equal Encoding::BINARY, value.encoding
          end
        end
      end
    end
  end
end
