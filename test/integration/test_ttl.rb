# frozen_string_literal: true

require_relative '../helper'

describe 'TTL behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'raises error with invalid client level expires_in' do
        bad_data = [{ bad: 'expires in data' }, Hash, [1, 2, 3]]

        bad_data.each do |bad|
          assert_raises ArgumentError do
            Dalli::Client.new('foo', { expires_in: bad })
          end
        end
      end

      it 'supports a TTL on set' do
        memcached_persistent(p) do |dc|
          key = 'foo'

          assert dc.set(key, 'bar', 1)
          assert_equal 'bar', dc.get(key)
          sleep 1.2

          assert_nil dc.get(key)
        end
      end

      it 'generates an ArgumentError for ttl that does not support to_i' do
        memcached_persistent(p) do |dc|
          assert_raises ArgumentError do
            dc.set('foo', 'bar', [])
          end
        end
      end

      it 'raises error with a client level expires_in that is not a whole number' do
        assert_raises(ArgumentError) { Dalli::Client.new('foo', { expires_in: 'abc' }) }
        assert_equal 300, Dalli::Client.new('foo', { expires_in: '300' }).instance_variable_get(:@options)[:expires_in]
      end

      # memcached rejects an expiry it can't hold with CLIENT_ERROR, which a
      # quiet block or set_multi silently discarded. A String that isn't a
      # whole number became 0, which means no expiry at all.
      describe 'with a TTL memcached cannot use' do
        bad_ttls = [2**40, 2**31, -(2**31) - 1, 'abc', '10x', Float::INFINITY]

        it 'raises ArgumentError from every operation that takes a TTL and stores nothing' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('existing', 'value')
            conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

            bad_ttls.each do |bad|
              assert_raises(ArgumentError, "set #{bad.inspect}") { dc.set('new', 'value', bad) }
              assert_raises(ArgumentError, "add #{bad.inspect}") { dc.add('new', 'value', bad) }
              assert_raises(ArgumentError, "replace #{bad.inspect}") { dc.replace('existing', 'changed', bad) }
              assert_raises(ArgumentError, "touch #{bad.inspect}") { dc.touch('existing', bad) }
              assert_raises(ArgumentError, "gat #{bad.inspect}") { dc.gat('existing', bad) }
              assert_raises(ArgumentError, "incr #{bad.inspect}") { dc.incr('counter', 1, bad, 0) }
              assert_raises(ArgumentError, "set_multi #{bad.inspect}") { dc.set_multi({ 'new' => 'value' }, bad) }
            end

            assert_predicate conn_mgr, :connected?, 'a bad TTL must not tear down the connection'
            assert_nil dc.get('new')
            assert_nil dc.get('counter')
            assert_equal 'value', dc.get('existing')
          end
        end

        it 'raises inside a quiet block instead of silently doing nothing' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush

            dc.quiet do
              dc.set('earlier', 'kept')
              assert_raises(ArgumentError) { dc.set('new', 'value', 2**40) }
            end

            assert_equal 'kept', dc.get('earlier')
            assert_nil dc.get('new')
          end
        end

        it 'raises from fetch_with_lock before calling the block' do
          memcached_persistent(p) do |dc|
            dc.flush
            called = false

            assert_raises(ArgumentError) { dc.fetch_with_lock('new', ttl: 2**40) { called = true } }
            refute called
          end
        end
      end

      it 'accepts the largest relative and absolute TTLs, and a TTL given as a String of decimal digits' do
        memcached_persistent(p) do |dc|
          dc.flush

          assert dc.set('relative', 'value', 30 * 24 * 60 * 60)
          assert dc.set('absolute', 'value', (2**31) - 1)
          assert dc.set('string', 'value', '300')
          assert_equal %w[value value value], [dc.get('relative'), dc.get('absolute'), dc.get('string')]
          assert_operator dc.get_with_metadata('string', return_ttl_remaining: true)[:ttl_remaining], :>, 0
        end
      end

      # memcached accepts a negative TTL and stores the item as already expired
      it 'accepts a negative TTL, which expires the item' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('existing', 'value')

          assert dc.set('expired', 'value', -1)
          assert dc.touch('existing', -1)
          assert dc.set('oldest', 'value', -(2**31))
          assert_nil dc.get('expired')
          assert_nil dc.get('existing')
          assert_nil dc.get('oldest')
        end
      end
    end
  end
end
