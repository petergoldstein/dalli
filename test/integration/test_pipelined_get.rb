# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Get' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'supports pipelined get' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          resp = dc.get_multi(%w[a b c d e f])

          assert_empty(resp)

          dc.set('a', 'foo')
          dc.set('b', 123)
          dc.set('c', %w[a b c])

          # Invocation without block
          resp = dc.get_multi(%w[a b c d e f])
          expected_resp = { 'a' => 'foo', 'b' => 123, 'c' => %w[a b c] }

          assert_equal(expected_resp, resp)

          # Invocation with block
          dc.get_multi(%w[a b c d e f]) do |k, v|
            assert(expected_resp.key?(k) && expected_resp[k] == v)
            expected_resp.delete(k)
          end

          assert_empty expected_resp

          # Perform a big quiet set with 1000 elements.
          arr = []
          dc.multi do
            1000.times do |idx|
              dc.set idx, idx
              arr << idx
            end
          end

          # Retrieve the elements with a pipelined get
          result = dc.get_multi(arr)

          assert_equal(1000, result.size)
          assert_equal(50, result['50'])
        end
      end

      it 'supports pipelined get with keys containing Unicode or spaces' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush

          keys_to_query = ['a', 'b', 'contains space', 'ƒ©åÍÎ']

          resp = dc.get_multi(keys_to_query)

          assert_empty(resp)

          dc.set('a', 'foo')
          dc.set('contains space', 123)
          dc.set('ƒ©åÍÎ', %w[a b c])

          # Invocation without block
          resp = dc.get_multi(keys_to_query)
          expected_resp = { 'a' => 'foo', 'contains space' => 123, 'ƒ©åÍÎ' => %w[a b c] }

          assert_equal(expected_resp, resp)

          # Invocation with block
          dc.get_multi(keys_to_query) do |k, v|
            assert(expected_resp.key?(k) && expected_resp[k] == v)
            expected_resp.delete(k)
          end

          assert_empty expected_resp
        end
      end

      describe 'pipeline_next_responses' do
        it 'raises NetworkError when called before pipeline_response_setup' do
          memcached_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            server.request(:pipelined_get, %w[a b])
            assert_raises Dalli::NetworkError do
              server.pipeline_next_responses
            end
          end
        end

        it 'raises NetworkError when called after pipeline_abort' do
          memcached_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            server.request(:pipelined_get, %w[a b])
            server.pipeline_response_setup
            server.pipeline_abort
            assert_raises Dalli::NetworkError do
              server.pipeline_next_responses
            end
          end
        end
      end
    end
  end
end

describe 'Pipelined Get on a multi-server ring' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'keeps the connection aligned when a key is long once base64-encoded' do
        memcached_persistent(p, 21_345) do |_, port1|
          memcached_persistent(p, 21_346) do |_, port2|
            dc = Dalli::Client.new(["localhost:#{port1}", "localhost:#{port2}"], protocol: p)
            dc.flush
            many = Array.new(2000) { |i| "user:#{i}:token" }
            dc.quiet { many.each { |k| dc.set(k, "token-for-#{k}") } }
            dc.set('victim:email', 'victim@example.com')
            # Under 250 characters, but over 250 bytes (and further over once
            # base64-encoded for the meta protocol)
            long_key = "search:#{'é' * 130}"
            dc.set(long_key, 'search-result')

            result = dc.get_multi_cas(long_key, *many)

            many.each { |k| assert_equal "token-for-#{k}", result[k]&.first }
            # A truncated key comes back under its truncated form, as for any
            # key over the limit, so check the value rather than the key
            assert_includes result.values.map(&:first), 'search-result'
            assert_equal 'search-result', dc.get(long_key)
            assert_equal 'victim@example.com', dc.get('victim:email')
            assert_equal 'token-for-user:5:token', dc.get('user:5:token')
          end
        end
      end

      it 'returns an empty value without cutting off the rest of its server' do
        memcached_persistent(p, 21_345) do |_, port1|
          memcached_persistent(p, 21_346) do |_, port2|
            dc = Dalli::Client.new(["localhost:#{port1}", "localhost:#{port2}"], raw: true, protocol: p)
            dc.flush
            big = 'x' * 20_000
            many = Array.new(100) { |i| "key#{i}" }
            # 3.2.x applies raw per request, so pass it to set explicitly
            many.each { |k| dc.set(k, big, 0, raw: true) }
            dc.set('key5', '', 0, raw: true)
            expected = many.to_h { |k| [k, k == 'key5' ? '' : big] }

            assert_equal expected, dc.get_multi(many)

            yielded = {}
            dc.get_multi(many) { |k, v| yielded[k] = v }

            assert_equal expected, yielded
            # Nothing is left unread on either connection
            many.each { |k| assert_equal expected[k], dc.get(k) }
          end
        end
      end
    end
  end
end
