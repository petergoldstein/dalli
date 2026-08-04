# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Delete' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'single-server delete_multi fast path' do
        it 'deletes multiple keys' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('d1', 'v1')
            dc.set('d2', 'v2')
            dc.set('d3', 'v3')

            assert_equal 'v1', dc.get('d1')

            dc.delete_multi(%w[d1 d2 d3])

            assert_nil dc.get('d1')
            assert_nil dc.get('d2')
            assert_nil dc.get('d3')
          end
        end

        it 'handles empty array' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.delete_multi([])
          end
        end

        it 'handles non-existent keys' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.delete_multi(%w[nonexistent1 nonexistent2])
          end
        end

        it 'only deletes specified keys' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('keep', 'keep_val')
            dc.set('remove', 'remove_val')

            dc.delete_multi(['remove'])

            assert_equal 'keep_val', dc.get('keep')
            assert_nil dc.get('remove')
          end
        end

        it 'handles Unicode and space keys' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('contains space', 'space_val')
            dc.set('ƒ©åÍÎ', 'unicode_val')

            dc.delete_multi(['contains space', 'ƒ©åÍÎ'])

            assert_nil dc.get('contains space')
            assert_nil dc.get('ƒ©åÍÎ')
          end
        end

        it 'handles large batch' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            keys = []
            100.times do |i|
              key = "del_bulk_#{i}"
              dc.set(key, "val_#{i}")
              keys << key
            end

            dc.delete_multi(keys)

            assert_nil dc.get('del_bulk_0')
            assert_nil dc.get('del_bulk_99')
          end
        end

        it 'returns the number of keys that were deleted' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('del_key1', 'value1')
            dc.set('del_key2', 'value2')

            assert_equal 2, dc.delete_multi(%w[del_key1 del_key2])
          end
        end

        it 'does not count keys that were not found' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('del_key1', 'value1')

            assert_equal 1, dc.delete_multi(%w[del_key1 missing_key])
          end
        end

        it 'retries on a transient (retryable) network error and returns the real count' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('del_key1', 'value1')
            dc.set('del_key2', 'value2')

            server = dc.send(:ring).servers.first
            original_request = server.method(:request)
            attempts = 0
            flaky_request = lambda do |opkey, *args|
              if opkey == :delete_multi_req
                attempts += 1
                raise Dalli::RetryableNetworkError, 'transient blip' if attempts == 1
              end

              original_request.call(opkey, *args)
            end

            server.stub(:request, flaky_request) do
              assert_equal 2, dc.delete_multi(%w[del_key1 del_key2])
            end

            assert_equal 2, attempts
          end
        end

        it 'raises Dalli::NetworkError on a terminal (non-retryable) network error' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set('del_key1', 'value1')

            server = dc.send(:ring).servers.first
            failing_request = lambda do |opkey, *args|
              raise Dalli::NetworkError, 'localhost is down' if opkey == :delete_multi_req

              raise "unexpected request: #{opkey}, #{args.inspect}"
            end

            server.stub(:request, failing_request) do
              assert_raises(Dalli::NetworkError) { dc.delete_multi(%w[del_key1]) }
            end
          end
        end
      end

      describe 'multi-server delete_multi pipelined path' do
        it 'aggregates the number of keys deleted per server' do
          memcached_persistent(p) do |dc|
            ring = dc.send(:ring)

            assert_equal 2, ring.servers.size

            dc.flush

            keys = (0...6).map { |i| "multi_del_#{i}" }
            keys.each { |k| dc.set(k, 'value') }

            assert_equal 2, keys.map { |k| ring.server_for_key(k) }.uniq.size
            assert_equal 6, dc.delete_multi(keys)
          end
        end

        it 'does not count keys that were not found' do
          memcached_persistent(p) do |dc|
            ring = dc.send(:ring)

            assert_equal 2, ring.servers.size

            dc.flush

            keys = (0...6).map { |i| "multi_del_#{i}" }
            keys.each { |k| dc.set(k, 'value') }

            assert_equal 2, keys.map { |k| ring.server_for_key(k) }.uniq.size
            assert_equal 6, dc.delete_multi(keys + ['missing_key'])
          end
        end

        it 'does not count keys that fail to enqueue' do
          memcached_persistent(p) do |dc|
            ring = dc.send(:ring)
            dc.flush

            dc.set('successful_key', 'value1')
            dc.set('failing_key', 'value2')

            failing_key_server = ring.server_for_key('failing_key')

            original_request = failing_key_server.method(:request)
            failing_request = lambda do |opkey, *args|
              if opkey == :pipelined_delete && args.first == 'failing_key'
                raise Dalli::DalliError,
                      'error writing request'
              end

              original_request.call(opkey, *args)
            end

            failing_key_server.stub(:request, failing_request) do
              assert_equal 1, dc.delete_multi(%w[successful_key failing_key])
            end

            assert_equal 'value2', dc.get('failing_key')
          end
        end
      end
    end
  end
end
