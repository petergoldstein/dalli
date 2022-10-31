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

          assert cas.is_a?(Integer)

          assert_equal 'value2', dc.get('key')
        end
      end

      # There's a bug in some versions of memcached where
      # the meta delete doesn't honor the CAS argument
      # Ensure our tests run correctly when used with
      # either set of versions
      if MemcachedManager.supports_delete_cas?(p)
        it 'supports delete with CAS' do
          memcached_persistent(p) do |dc|
            cas = dc.set('some_key', 'some_value')

            # It returns falsey and doesn't delete
            # when the CAS is wrong
            refute dc.delete_cas('some_key', 123)
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
      end
    end
  end
end
