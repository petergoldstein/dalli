# frozen_string_literal: true

require_relative '../helper'
require 'json'

describe 'Serializer configuration' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'defaults to Marshal' do
        memcached(p, 29_198) do |dc|
          dc.set 1, 2

          assert_equal Marshal, dc.instance_variable_get(:@ring).servers.first.serializer
        end
      end

      it 'skips the serializer for simple strings when string_fastpath is enabled' do
        memcached(p, 29_198) do |_dc, port|
          dump_calls = 0
          spy = Module.new do
            define_singleton_method(:dump) do |v|
              dump_calls += 1
              Marshal.dump(v)
            end
            define_singleton_method(:load) { |v| Marshal.load(v) } # rubocop:disable Security/MarshalLoad
          end

          memcache = Dalli::Client.new("127.0.0.1:#{port}",
                                       string_fastpath: true,
                                       serializer: spy,
                                       silence_marshal_warning: true)
          string = 'héllø'
          memcache.set 'utf-8', string

          assert_equal string, memcache.get('utf-8')
          assert_equal Encoding::UTF_8, memcache.get('utf-8').encoding

          binary = "\0\xff".b
          memcache.set 'binary', binary

          assert_equal binary, memcache.get('binary')
          assert_equal Encoding::BINARY, memcache.get('binary').encoding

          # UTF-8 and binary bypass the serializer; assert the spy was not called.
          assert_equal 0, dump_calls, 'serializer#dump should not be called for UTF-8 or binary strings'

          # Non-UTF-8/binary encodings still go through the serializer.
          latin1 = string.encode(Encoding::ISO_8859_1)
          memcache.set 'latin1', latin1

          assert_equal 1, dump_calls, 'serializer#dump should be called for non-UTF-8/binary strings'
          assert_equal latin1, memcache.get('latin1')
          assert_equal Encoding::ISO_8859_1, memcache.get('latin1').encoding

          # Ensure strings written via the fastpath are properly retrieved
          # by clients without string_fastpath enabled.
          plain = Dalli::Client.new("127.0.0.1:#{port}",
                                    string_fastpath: false,
                                    serializer: spy,
                                    silence_marshal_warning: true)

          assert_equal string, plain.get('utf-8')
          assert_equal Encoding::UTF_8, plain.get('utf-8').encoding
          assert_equal binary, plain.get('binary')
          assert_equal Encoding::BINARY, plain.get('binary').encoding
          assert_equal latin1, plain.get('latin1')
          assert_equal Encoding::ISO_8859_1, plain.get('latin1').encoding
        end
      end

      it 'respects per-request string_fastpath overriding the client-level option' do
        memcached(p, 29_198) do |_dc, port|
          dump_calls = 0
          spy = Module.new do
            define_singleton_method(:dump) do |v|
              dump_calls += 1
              Marshal.dump(v)
            end
            define_singleton_method(:load) { |v| Marshal.load(v) } # rubocop:disable Security/MarshalLoad
          end

          # Client-level true, per-request false: serializer must be called.
          memcache = Dalli::Client.new("127.0.0.1:#{port}",
                                       string_fastpath: true,
                                       serializer: spy,
                                       silence_marshal_warning: true)
          memcache.set 'key', 'value', nil, string_fastpath: false

          assert_equal 1, dump_calls, 'per-request false should override client-level true'
          assert_equal 'value', memcache.get('key')

          # Client-level false, per-request true: serializer must not be called.
          dump_calls = 0
          plain = Dalli::Client.new("127.0.0.1:#{port}",
                                    string_fastpath: false,
                                    serializer: spy,
                                    silence_marshal_warning: true)
          plain.set 'key2', 'value2', nil, string_fastpath: true

          assert_equal 0, dump_calls, 'per-request true should override client-level false'
          assert_equal 'value2', plain.get('key2')
        end
      end

      it 'round-trips fastpath strings when compression is enabled (per-request option)' do
        # Regression test for the collision between the UTF8 fastpath flag and
        # the COMPRESSED flag — both occupy bit 0x2 in ValueSerializer and
        # ValueCompressor respectively. The bug only surfaces when
        # `string_fastpath: true` is passed as a per-request option on `#set`,
        # which is the path real callers like Rails' `mem_cache_store` use
        # (it forwards all per-call options to Dalli except `:compress`).
        memcached(p, 29_198) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}",
                                       compress: true,
                                       compression_min_size: 1024)

          # Short UTF-8 — below the compression threshold, but the fastpath
          # still sets the UTF8 flag bit. Without the fix, the reader's
          # compressor sees the bit as "compressed" and raises Zlib::DataError
          # (wrapped as Dalli::UnmarshalError).
          short_utf8 = 'héllø'
          memcache.set 'short_utf8', short_utf8, 60, string_fastpath: true

          assert_equal short_utf8, memcache.get('short_utf8')
          assert_equal Encoding::UTF_8, memcache.get('short_utf8').encoding

          # Long UTF-8 — over the compression threshold. Compressor and
          # fastpath both want to set their flag bit on the same value.
          long_utf8 = ('héllo-вселенная-🌍 ' * 600).force_encoding(Encoding::UTF_8).freeze
          memcache.set 'long_utf8', long_utf8, 60, string_fastpath: true

          assert_equal long_utf8, memcache.get('long_utf8')
          assert_equal Encoding::UTF_8, memcache.get('long_utf8').encoding

          # Long BINARY — fastpath leaves no encoding flag, compressor adds
          # the compression flag. Without the fix the reader returns the
          # decompressed bytes with the wrong encoding.
          long_binary = ("\xFFpayload" * 2000).b.freeze
          memcache.set 'long_binary', long_binary, 60, string_fastpath: true

          assert_equal long_binary, memcache.get('long_binary')
          assert_equal Encoding::BINARY, memcache.get('long_binary').encoding

          # A second client that never opts into fastpath must still read
          # every entry correctly — covers a rolling-deploy or worker-pool
          # mismatch where only some processes use the per-request option.
          plain = Dalli::Client.new("127.0.0.1:#{port}",
                                    compress: true,
                                    compression_min_size: 1024)

          assert_equal short_utf8, plain.get('short_utf8')
          assert_equal Encoding::UTF_8, plain.get('short_utf8').encoding
          assert_equal long_utf8, plain.get('long_utf8')
          assert_equal Encoding::UTF_8, plain.get('long_utf8').encoding
          assert_equal long_binary, plain.get('long_binary')
          assert_equal Encoding::BINARY, plain.get('long_binary').encoding
        end
      end

      it 'supports a custom serializer' do
        memcached(p, 29_198) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", serializer: JSON)
          memcache.set 1, 2
          begin
            assert_equal JSON, memcache.instance_variable_get(:@ring).servers.first.serializer

            memcached(p, 21_956) do |newdc|
              assert newdc.set('json_test', { 'foo' => 'bar' })
              assert_equal({ 'foo' => 'bar' }, newdc.get('json_test'))
            end
          end
        end
      end

      it 'supports no serialization' do
        memcached(p, 29_198) do |_dc, port|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", raw: true)

          with_nil_logger do
            error = assert_raises(Dalli::MarshalError) do
              memcache.set '1', 2
            end
            assert_match 'Integer', error.message
          end

          memcache.set '1', '2'

          memcached(p, 21_956, '', { raw: true }) do |newdc|
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
