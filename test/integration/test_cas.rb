# frozen_string_literal: true

require_relative '../helper'

describe 'CAS behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'get_cas' do
        describe 'when no block is given' do
          it 'returns the value and a CAS' do
            memcached_persistent(p) do |dc|
              dc.flush

              dc.set('key1', 'abcd')
              value, cas = dc.get_cas('key1')

              assert_equal 'abcd', value
              assert valid_cas?(cas)
            end
          end

          # This is historical, as the 'Not found' value was
          # treated as a special case at one time
          it 'allows "Not found" as value' do
            memcached_persistent(p) do |dc|
              dc.flush

              dc.set('key1', 'Not found')
              value, cas = dc.get_cas('key1')

              assert_equal 'Not found', value
              assert valid_cas?(cas)
            end
          end

          it 'returns [nil, 0] on a miss' do
            memcached_persistent(p) do |dc|
              dc.flush
              value, cas = dc.get_cas('key1')

              assert_nil value
              assert_equal 0, cas
            end
          end
        end

        describe 'when a block is given' do
          it 'yields the value and a CAS to the block' do
            memcached_persistent(p) do |dc|
              dc.flush

              expected = { 'blah' => 'blerg!' }

              set_cas = dc.set('gets_key', expected)
              get_block_called = false
              block_value = SecureRandom.hex(4)
              stored_value = stored_cas = nil

              # Validate call-with-block on hit
              res = dc.get_cas('gets_key') do |v, cas|
                get_block_called = true
                stored_value = v
                stored_cas = cas
                block_value
              end

              assert get_block_called
              assert_equal expected, stored_value
              assert valid_cas?(stored_cas)
              assert_equal set_cas, stored_cas
              assert_equal block_value, res
            end
          end

          # This is historical, as the 'Not found' value was
          # treated as a special case at one time
          it 'allows "Not found" as value' do
            memcached_persistent(p) do |dc|
              dc.flush

              expected = 'Not found'

              set_cas = dc.set('gets_key', expected)
              get_block_called = false
              block_value = SecureRandom.hex(4)
              stored_value = stored_cas = nil

              # Validate call-with-block on hit
              res = dc.get_cas('gets_key') do |v, cas|
                get_block_called = true
                stored_value = v
                stored_cas = cas
                block_value
              end

              assert get_block_called
              assert_equal expected, stored_value
              assert valid_cas?(stored_cas)
              assert_equal set_cas, stored_cas
              assert_equal block_value, res
            end
          end

          it 'yields [nil, 0] to the block on a miss' do
            memcached_persistent(p) do |dc|
              dc.flush

              get_block_called = false
              block_value = SecureRandom.hex(4)
              stored_value = stored_cas = nil
              # Validate call-with-block on miss
              res = dc.get_cas('gets_key') do |v, cas|
                get_block_called = true
                stored_value = v
                stored_cas = cas
                block_value
              end

              assert get_block_called
              assert_nil stored_value
              assert_equal 0, stored_cas
              assert_equal block_value, res
            end
          end
        end
      end

      it 'supports multi-get with CAS' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush

          expected_hash = { 'a' => 'foo', 'b' => 123 }
          expected_hash.each_pair do |k, v|
            dc.set(k, v)
          end

          # Invocation without block
          resp = dc.get_multi_cas(%w[a b c d e f])
          resp.each_pair do |k, data|
            value = data.first
            cas = data[1]

            assert_equal expected_hash[k], value
            assert(cas && cas != 0)
          end

          # Invocation with block
          dc.get_multi_cas(%w[a b c d e f]) do |k, data|
            value = data.first
            cas = data[1]

            assert_equal expected_hash[k], value
            assert(cas && cas != 0)
          end
        end
      end

      it 'supports replace-with-CAS operation' do
        memcached_persistent(p) do |dc|
          dc.flush
          cas = dc.set('key', 'value')

          # Accepts CAS, replaces, and returns new CAS
          cas = dc.replace_cas('key', 'value2', cas)

          assert_kind_of Integer, cas

          assert_equal 'value2', dc.get('key')
        end
      end

      it 'supports delete with CAS' do
        memcached_persistent(p) do |dc|
          cas = dc.set('some_key', 'some_value')

          # It returns falsey and doesn't delete
          # when the CAS is wrong
          refute dc.delete_cas('some_key', cas + 1)
          assert_equal 'some_value', dc.get('some_key')

          dc.delete_cas('some_key', cas)

          assert_nil dc.get('some_key')

          refute dc.delete_cas('nonexist', 123)
        end
      end

      it 'handles CAS round-trip operations' do
        memcached_persistent(p) do |dc|
          dc.flush

          expected = { 'blah' => 'blerg!' }
          dc.set('some_key', expected)

          value, cas = dc.get_cas('some_key')

          assert_equal value, expected
          assert(!cas.nil? && cas != 0)

          # Set operation, first with wrong then with correct CAS
          expected = { 'blah' => 'set succeeded' }

          refute(dc.set_cas('some_key', expected, cas + 1))
          assert op_addset_succeeds(cas = dc.set_cas('some_key', expected, cas))

          # Replace operation, first with wrong then with correct CAS
          expected = { 'blah' => 'replace succeeded' }

          refute(dc.replace_cas('some_key', expected, cas + 1))
          assert op_addset_succeeds(cas = dc.replace_cas('some_key', expected, cas))

          # Delete operation, first with wrong then with correct CAS
          refute(dc.delete_cas('some_key', cas + 1))
          assert dc.delete_cas('some_key', cas)
        end
      end

      # A CAS that couldn't be parsed used to be dropped, turning the
      # compare-and-swap into an unconditional write
      describe 'with a CAS that is not an unsigned 64-bit integer' do
        bad_cas_values = ['abc', '123x', -1, 2**64]

        it 'raises from set_cas, replace_cas and delete_cas and leaves the item unchanged' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('cas_key', 'original')
            conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

            bad_cas_values.each do |bad|
              assert_raises(ArgumentError, "set_cas #{bad.inspect}") { dc.set_cas('cas_key', 'changed', bad) }
              assert_raises(ArgumentError, "replace_cas #{bad.inspect}") { dc.replace_cas('cas_key', 'changed', bad) }
              assert_raises(ArgumentError, "delete_cas #{bad.inspect}") { dc.delete_cas('cas_key', bad) }
            end

            assert_predicate conn_mgr, :connected?, 'a bad CAS must not tear down the connection'
            assert_equal 'original', dc.get('cas_key')
          end
        end

        it 'raises inside a quiet block without discarding earlier quiet writes' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('cas_key', 'original')

            dc.quiet do
              dc.set('earlier', 'kept')
              assert_raises(ArgumentError) { dc.set_cas('cas_key', 'changed', 'abc') }
            end

            assert_equal 'kept', dc.get('earlier')
            assert_equal 'original', dc.get('cas_key')
          end
        end
      end

      it 'accepts a CAS given as a String of decimal digits' do
        memcached_persistent(p) do |dc|
          dc.flush
          cas = dc.set('cas_key', 'original')

          refute dc.set_cas('cas_key', 'changed', (cas + 1).to_s)
          assert op_addset_succeeds(dc.set_cas('cas_key', 'changed', cas.to_s))
          assert_equal 'changed', dc.get('cas_key')
        end
      end

      describe 'flush' do
        bad_delays = ['abc', '10x', -1, 1.5]

        it 'raises on a delay that is not a non-negative integer and flushes nothing' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('survivor', 'value')
            conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

            bad_delays.each do |bad|
              assert_raises(ArgumentError, "flush #{bad.inspect}") { dc.flush(bad) }
            end

            assert_predicate conn_mgr, :connected?, 'a bad flush delay must not tear down the connection'
            assert_equal 'value', dc.get('survivor')
          end
        end
      end

      describe 'cas' do
        it 'does not call the block when the key has no existing value' do
          memcached_persistent(p) do |dc|
            dc.flush

            resp = dc.cas('cas_key') do |_value|
              raise('Value it not exist')
            end

            assert_nil resp
            assert_nil dc.cas('cas_key')
          end
        end

        it 'calls the block and sets a new value when the key has an existing value' do
          memcached_persistent(p) do |dc|
            dc.flush

            expected = { 'blah' => 'blerg!' }
            dc.set('cas_key', expected)

            mutated = { 'blah' => 'foo!' }
            resp = dc.cas('cas_key') do |value|
              assert_equal expected, value
              mutated
            end

            assert op_cas_succeeds(resp)

            resp = dc.get('cas_key')

            assert_equal mutated, resp
          end
        end

        it "calls the block and sets a new value when the key has the value 'Not found'" do
          memcached_persistent(p) do |dc|
            dc.flush

            expected = 'Not found'
            dc.set('cas_key', expected)

            mutated = { 'blah' => 'foo!' }
            resp = dc.cas('cas_key') do |value|
              assert_equal expected, value
              mutated
            end

            assert op_cas_succeeds(resp)

            resp = dc.get('cas_key')

            assert_equal mutated, resp
          end
        end

        it 'does not call the block when the key holds a stored nil and cache_nils is false' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('cas_key', nil)

            resp = dc.cas('cas_key') { |_value| raise('block should not be called') }

            assert_nil resp
          end
        end

        it 'calls the block when the key holds a stored nil and cache_nils is true' do
          memcached_persistent(p, 21_345, '', { cache_nils: true }) do |dc|
            dc.flush
            dc.set('cas_key', nil)

            called = false
            resp = dc.cas('cas_key') do |value|
              called = true

              assert_nil value
              'mutated'
            end

            assert called
            assert op_cas_succeeds(resp)
            assert_equal 'mutated', dc.get('cas_key')
          end
        end

        it 'does not call the block on a miss when cache_nils is true' do
          memcached_persistent(p, 21_345, '', { cache_nils: true }) do |dc|
            dc.flush

            resp = dc.cas('cas_key') { |_value| raise('block should not be called') }

            assert_nil resp
            assert_nil dc.get('cas_key')
          end
        end
      end

      describe 'cas!' do
        it 'calls the block and sets a new value  when the key has no existing value' do
          memcached_persistent(p) do |dc|
            dc.flush

            mutated = { 'blah' => 'foo!' }
            resp = dc.cas!('cas_key') do |value|
              assert_nil value
              mutated
            end

            assert op_cas_succeeds(resp)

            resp = dc.get('cas_key')

            assert_equal mutated, resp
          end
        end

        it 'calls the block and sets a new value when the key has an existing value' do
          memcached_persistent(p) do |dc|
            dc.flush

            expected = { 'blah' => 'blerg!' }
            dc.set('cas_key', expected)

            mutated = { 'blah' => 'foo!' }
            resp = dc.cas!('cas_key') do |value|
              assert_equal expected, value
              mutated
            end

            assert op_cas_succeeds(resp)

            resp = dc.get('cas_key')

            assert_equal mutated, resp
          end
        end

        it "calls the block and sets a new value when the key has the value 'Not found'" do
          memcached_persistent(p) do |dc|
            dc.flush

            expected = 'Not found'
            dc.set('cas_key', expected)

            mutated = { 'blah' => 'foo!' }
            resp = dc.cas!('cas_key') do |value|
              assert_equal expected, value
              mutated
            end

            assert op_cas_succeeds(resp)

            resp = dc.get('cas_key')

            assert_equal mutated, resp
          end
        end

        it 'does not overwrite a value created by another writer when the key has no existing value' do
          memcached_persistent(p) do |dc|
            dc.flush

            resp = dc.cas!('cas_key') do |value|
              assert_nil value
              # Another client creates the key while the block runs
              dc.set('cas_key', 'other writer')
              'mine'
            end

            refute resp
            assert_equal 'other writer', dc.get('cas_key')
          end
        end

        it 'calls the block with nil when the key holds a stored nil and cache_nils is true' do
          memcached_persistent(p, 21_345, '', { cache_nils: true }) do |dc|
            dc.flush
            dc.set('cas_key', nil)

            resp = dc.cas!('cas_key') do |value|
              assert_nil value
              'mutated'
            end

            assert op_cas_succeeds(resp)
            assert_equal 'mutated', dc.get('cas_key')
          end
        end
      end
    end
  end
end
