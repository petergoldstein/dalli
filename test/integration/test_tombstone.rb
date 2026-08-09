# frozen_string_literal: true

require_relative '../helper'

describe 'tombstone deletes' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      def metadata(dalli_client, key)
        dalli_client.get_with_metadata(key).slice(:value, :miss, :stale)
      end

      it 'removes the item entirely without invalidate' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('plain', 'value')

          assert dc.delete('plain')
          assert_equal({ value: nil, miss: true, stale: false }, metadata(dc, 'plain'))
        end
      end

      # The point of the tombstone: a reader can tell "someone is repopulating
      # this" apart from "this was never here".
      it 'leaves a readable stale item when invalidating' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('tomb', 'original')

          assert dc.delete('tomb', invalidate: true)
          assert_equal({ value: 'original', miss: false, stale: true }, metadata(dc, 'tomb'))
        end
      end

      it 'drops the payload but keeps the marker with invalidate and drop_value' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('tomb', 'original')

          assert dc.delete('tomb', invalidate: true, drop_value: true)
          assert_equal({ value: '', miss: false, stale: true }, metadata(dc, 'tomb'))
        end
      end

      # drop_value on its own is not a tombstone -- there is no stale marker,
      # just an item whose value is gone.
      it 'does not mark the item stale for drop_value alone' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('dropped', 'original')

          assert dc.delete('dropped', drop_value: true)
          assert_equal({ value: '', miss: false, stale: false }, metadata(dc, 'dropped'))
        end
      end

      it 'expires the tombstone after tombstone_ttl' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('expiring', 'original')
          dc.delete('expiring', invalidate: true, tombstone_ttl: 1)

          assert_equal({ value: 'original', miss: false, stale: true }, metadata(dc, 'expiring'))

          sleep 2

          assert_equal({ value: nil, miss: true, stale: false }, metadata(dc, 'expiring'))
        end
      end

      it 'reports the tombstone TTL through return_ttl_remaining' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('ttl_tomb', 'original')
          dc.delete('ttl_tomb', invalidate: true, tombstone_ttl: 60)

          result = dc.get_with_metadata('ttl_tomb', return_ttl_remaining: true)

          assert result[:stale]
          assert_operator result[:ttl_remaining], :positive?
          assert_operator result[:ttl_remaining], :<=, 60
        end
      end

      it 'honors CAS alongside invalidate' do
        memcached_persistent(p) do |dc|
          dc.flush
          cas = dc.set('cas_tomb', 'original')

          refute dc.delete_cas('cas_tomb', cas + 1, invalidate: true)
          refute metadata(dc, 'cas_tomb')[:stale], 'a failed CAS must not tombstone the item'

          assert dc.delete_cas('cas_tomb', cas, invalidate: true)
          assert metadata(dc, 'cas_tomb')[:stale]
        end
      end

      describe 'delete_multi' do
        # Exercised on both routing paths: memcached_persistent yields a client
        # with a two-entry ring (the pipelined deleter), single_server_client
        # takes the single-server fast path.
        it 'tombstones every key in the batch via the pipelined path' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'va')
            dc.set('b', 'vb')

            dc.delete_multi(%w[a b], invalidate: true)

            assert_equal({ value: 'va', miss: false, stale: true }, metadata(dc, 'a'))
            assert_equal({ value: 'vb', miss: false, stale: true }, metadata(dc, 'b'))
          end
        end

        it 'tombstones every key in the batch via the single-server path' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('a', 'va')
            dc.set('b', 'vb')

            dc.delete_multi(%w[a b], invalidate: true, tombstone_ttl: 60)

            assert_equal({ value: 'va', miss: false, stale: true }, metadata(dc, 'a'))
            assert_equal({ value: 'vb', miss: false, stale: true }, metadata(dc, 'b'))
          end
        end

        it 'still removes keys outright without invalidate' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'va')
            dc.set('b', 'vb')

            assert_equal 2, dc.delete_multi(%w[a b])
            assert_equal({ value: nil, miss: true, stale: false }, metadata(dc, 'a'))
          end
        end

        it 'drops the payload in bulk with drop_value' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'va')

            dc.delete_multi(%w[a], invalidate: true, drop_value: true)

            assert_equal({ value: '', miss: false, stale: true }, metadata(dc, 'a'))
          end
        end

        # The count means "keys the server found and acted on". Only a key that
        # did not exist decrements it, so tombstoning counts exactly as deleting
        # does -- the caller chose the action.
        it 'counts tombstoned keys the same as deleted ones' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'va')
            dc.set('b', 'vb')

            assert_equal 2, dc.delete_multi(%w[a b never_stored], invalidate: true)
          end
        end

        it 'excludes keys that did not exist from the count' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('only', 'v')

            assert_equal 1, dc.delete_multi(%w[only missing1 missing2], invalidate: true)
          end
        end

        it 'raises for tombstone_ttl without invalidate' do
          memcached_persistent(p) do |dc|
            error = assert_raises(ArgumentError) { dc.delete_multi(%w[a b], tombstone_ttl: 30) }

            assert_equal 'tombstone_ttl requires invalidate: true', error.message
          end
        end

        it 'rejects bad options before touching the connection' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('survivor', 'value')
            conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

            assert_raises(ArgumentError) { dc.delete_multi(%w[survivor], tombstone_ttl: 30) }

            assert_predicate conn_mgr, :connected?, 'bad options must not tear down the connection'
            assert_equal 'value', dc.get('survivor')
          end
        end

        it 'returns 0 for an empty key list' do
          memcached_persistent(p) do |dc|
            assert_equal 0, dc.delete_multi([], invalidate: true)
          end
        end
      end

      describe 'tombstone_ttl without invalidate' do
        it 'raises ArgumentError' do
          memcached_persistent(p) do |dc|
            error = assert_raises(ArgumentError) { dc.delete('anything', tombstone_ttl: 30) }

            assert_equal 'tombstone_ttl requires invalidate: true', error.message
          end
        end

        # Rejecting the options must not cost the caller its connection.  Reaching
        # the formatter's guard instead would unwind through Protocol::Base#request,
        # which closes the socket -- invisible through the client, which just
        # reconnects, so this asserts on the connection itself.
        it 'does not close the connection' do
          # Single-server client so the connection asserted on is unambiguously
          # the one the delete would have used.
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('survivor', 'value')
            conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

            assert_predicate conn_mgr, :connected?, 'precondition: connected after a set'

            assert_raises(ArgumentError) { dc.delete('survivor', tombstone_ttl: 30) }

            assert_predicate conn_mgr, :connected?, 'bad options must not tear down the connection'
            assert_equal 'value', dc.get('survivor')
          end
        end
      end

      describe 'non-integer tombstone_ttl' do
        # tombstone_kwargs coerces tombstone_ttl with Integer() deep inside the
        # request path; without a client-side type check that raise unwinds
        # through Protocol::Base#request and closes the connection, same as an
        # unvalidated tombstone_ttl/invalidate pairing.
        it 'raises ArgumentError without closing the connection' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('survivor', 'value')
            conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

            error = assert_raises(ArgumentError) do
              dc.delete('survivor', invalidate: true, tombstone_ttl: 'not-a-number')
            end

            assert_equal 'tombstone_ttl must be an integer, got "not-a-number"', error.message
            assert_predicate conn_mgr, :connected?, 'bad tombstone_ttl type must not tear down the connection'
            assert_equal 'value', dc.get('survivor')
          end
        end
      end
    end
  end
end
