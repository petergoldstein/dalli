# frozen_string_literal: true

require_relative '../helper'
require 'openssl'
require 'securerandom'

describe 'operations' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'get' do
        it 'returns the value on a hit' do
          memcached_persistent(p) do |dc|
            dc.flush

            val1 = '1234567890' * 999_999
            dc.set('a', val1)
            val2 = dc.get('a')

            assert_equal val1, val2

            assert op_addset_succeeds(dc.set('a', nil))
            assert_nil dc.get('a')
          end
        end

        it 'return the value that include TERMINATOR on a hit' do
          memcached_persistent(p) do |dc|
            dc.flush

            val1 = "12345#{Dalli::Protocol::Meta::TERMINATOR}67890"
            dc.set('a', val1)
            val2 = dc.get('a')

            assert_equal val1, val2

            assert op_addset_succeeds(dc.set('a', nil))
            assert_nil dc.get('a')
          end
        end

        it 'returns nil on a miss' do
          memcached_persistent(p) do |dc|
            assert_nil dc.get('notexist')
          end
        end

        # This is historical, as the 'Not found' value was
        # treated as a special case at one time
        it 'allows "Not found" as value' do
          memcached_persistent(p) do |dc|
            dc.set('key1', 'Not found')

            assert_equal 'Not found', dc.get('key1')
          end
        end
      end

      describe 'raw mode validation' do
        it 'raises MarshalError when setting nil with raw: true' do
          memcached_persistent(p) do |dc|
            error = assert_raises Dalli::MarshalError do
              dc.set('rawkey', nil, 0, raw: true)
            end

            assert_match(/raw mode requires string values/, error.message)
            assert_match(/NilClass/, error.message)
          end
        end

        it 'raises MarshalError when setting non-string with raw: true' do
          memcached_persistent(p) do |dc|
            error = assert_raises Dalli::MarshalError do
              dc.set('rawkey', 123, 0, raw: true)
            end

            assert_match(/raw mode requires string values/, error.message)
            assert_match(/Integer/, error.message)
          end
        end

        it 'allows setting strings with raw: true' do
          memcached_persistent(p) do |dc|
            dc.flush

            assert op_addset_succeeds(dc.set('rawkey', 'string_value', 0, raw: true))
            assert_equal 'string_value', dc.get('rawkey', raw: true)
          end
        end
      end

      describe 'gat' do
        it 'returns the value and touches on a hit' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set 'key', 'value'

            assert_equal 'value', dc.gat('key', 10)
            assert_equal 'value', dc.gat('key')
          end
        end

        it 'returns nil on a miss' do
          memcached_persistent(p) do |dc|
            dc.flush

            assert_nil dc.gat('notexist', 10)
          end
        end
      end

      describe 'touch' do
        it 'returns true on a hit' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set 'key', 'value'

            assert dc.touch('key', 10)
            assert dc.touch('key')
            assert_equal 'value', dc.get('key')
            assert_nil dc.touch('notexist')
          rescue Dalli::DalliError => e
            # This will happen when memcached is in lesser version than 1.4.8
            assert_equal 'Response error 129: Unknown command', e.message
          end
        end

        it 'returns nil on a miss' do
          memcached_persistent(p) do |dc|
            dc.flush

            assert_nil dc.touch('notexist')
          end
        end
      end

      describe 'set' do
        it 'returns a CAS when the key exists and updates the value' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('key', 'value')

            assert op_replace_succeeds(dc.set('key', 'value2'))

            assert_equal 'value2', dc.get('key')
          end
        end

        it 'returns a CAS when no pre-existing value exists' do
          memcached_persistent(p) do |dc|
            dc.flush

            assert op_replace_succeeds(dc.set('key', 'value2'))
            assert_equal 'value2', dc.get('key')
          end
        end
      end

      describe 'add' do
        it 'returns false when replacing an existing value and does not update the value' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('key', 'value')

            refute dc.add('key', 'value')

            assert_equal 'value', dc.get('key')
          end
        end

        it 'returns a CAS when no pre-existing value exists' do
          memcached_persistent(p) do |dc|
            dc.flush

            assert op_replace_succeeds(dc.add('key', 'value2'))
          end
        end
      end

      describe 'replace' do
        it 'returns a CAS when the key exists and updates the value' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('key', 'value')

            assert op_replace_succeeds(dc.replace('key', 'value2'))

            assert_equal 'value2', dc.get('key')
          end
        end

        it 'returns false when no pre-existing value exists' do
          memcached_persistent(p) do |dc|
            dc.flush

            refute dc.replace('key', 'value')
          end
        end
      end

      describe 'delete' do
        it 'returns true on a hit and deletes the entry' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('some_key', 'some_value')

            assert_equal 'some_value', dc.get('some_key')

            assert dc.delete('some_key')
            assert_nil dc.get('some_key')

            refute dc.delete('nonexist')
          end
        end

        it 'returns false on a miss' do
          memcached_persistent(p) do |dc|
            dc.flush

            refute dc.delete('nonexist')
          end
        end
      end

      describe 'fetch' do
        it 'fetches pre-existing values' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('fetch_key', 'Not found')
            res = dc.fetch('fetch_key') { flunk 'fetch block called' }

            assert_equal 'Not found', res
          end
        end

        it 'supports with default values' do
          memcached_persistent(p) do |dc|
            dc.flush

            expected = { 'blah' => 'blerg!' }
            executed = false
            value = dc.fetch('fetch_key') do
              executed = true
              expected
            end

            assert_equal expected, value
            assert executed

            executed = false
            value = dc.fetch('fetch_key') do
              executed = true
              expected
            end

            assert_equal expected, value
            refute executed
          end
        end

        it 'supports with falsey values' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('fetch_key', false)
            res = dc.fetch('fetch_key') { flunk 'fetch block called' }

            refute res
          end
        end

        it 'supports with nil values when cache_nils: true' do
          memcached_persistent(p, port_or_socket: 21_345, client_options: { cache_nils: true }) do |dc|
            dc.flush

            dc.set('fetch_key', nil)
            res = dc.fetch('fetch_key') { flunk 'fetch block called' }

            assert_nil res
          end

          memcached_persistent(p, port_or_socket: 21_345, client_options: { cache_nils: false }) do |dc|
            dc.flush
            dc.set('fetch_key', nil)
            executed = false
            res = dc.fetch('fetch_key') do
              executed = true
              'bar'
            end

            assert_equal 'bar', res
            assert executed
          end
        end
      end

      describe 'incr/decr' do
        it 'supports incrementing and decrementing existing values' do
          memcached_persistent(p) do |client|
            client.flush

            assert op_addset_succeeds(client.set('fakecounter', '0', 0, raw: true))
            assert_equal 1, client.incr('fakecounter', 1)
            assert_equal 2, client.incr('fakecounter', 1)
            assert_equal 3, client.incr('fakecounter', 1)
            assert_equal 1, client.decr('fakecounter', 2)
            assert_equal '1', client.get('fakecounter')
          end
        end

        it 'returns nil on a miss with no initial value' do
          memcached_persistent(p) do |client|
            client.flush

            resp = client.incr('mycounter', 1)

            assert_nil resp

            resp = client.decr('mycounter', 1)

            assert_nil resp
          end
        end

        it 'enables setting an initial value with incr and subsequently incrementing/decrementing' do
          memcached_persistent(p) do |client|
            client.flush

            resp = client.incr('mycounter', 1, 0, 2)

            assert_equal 2, resp
            resp = client.incr('mycounter', 1)

            assert_equal 3, resp

            resp = client.decr('mycounter', 2)

            assert_equal 1, resp
          end
        end

        it 'supports setting the initial value with decr and subsequently incrementing/decrementing' do
          memcached_persistent(p) do |dc|
            dc.flush

            resp = dc.decr('counter', 100, 5, 0)

            assert_equal 0, resp

            resp = dc.decr('counter', 10)

            assert_equal 0, resp

            resp = dc.incr('counter', 10)

            assert_equal 10, resp

            current = 10
            100.times do |x|
              resp = dc.incr('counter', 10)

              assert_equal current + ((x + 1) * 10), resp
            end
          end
        end

        it 'supports 64-bit values' do
          memcached_persistent(p) do |dc|
            dc.flush

            resp = dc.decr('10billion', 0, 5, 10)

            assert_equal 10, resp
            # go over the 32-bit mark to verify proper (un)packing
            resp = dc.incr('10billion', 10_000_000_000)

            assert_equal 10_000_000_010, resp

            resp = dc.decr('10billion', 1)

            assert_equal 10_000_000_009, resp

            resp = dc.decr('10billion', 0)

            assert_equal 10_000_000_009, resp

            resp = dc.incr('10billion', 0)

            assert_equal 10_000_000_009, resp

            resp = dc.decr('10billion', 9_999_999_999)

            assert_equal 10, resp

            resp = dc.incr('big', 100, 5, 0xFFFFFFFFFFFFFFFE)

            assert_equal 0xFFFFFFFFFFFFFFFE, resp
            resp = dc.incr('big', 1)

            assert_equal 0xFFFFFFFFFFFFFFFF, resp

            # rollover the 64-bit value, we'll get something undefined.
            resp = dc.incr('big', 1)

            refute_equal 0x10000000000000000, resp
            dc.reset
          end
        end
      end

      describe 'append/prepend' do
        it 'support the append and prepend operations' do
          memcached_persistent(p) do |dc|
            dc.flush

            assert op_addset_succeeds(dc.set('456', 'xyz', 0, raw: true))
            assert dc.prepend('456', '0')
            assert dc.append('456', '9')
            assert_equal '0xyz9', dc.get('456')

            refute dc.append('nonexist', 'abc')
            refute dc.prepend('nonexist', 'abc')
          end
        end
      end

      describe 'set_multi' do
        it 'sets multiple key-value pairs' do
          memcached_persistent(p) do |dc|
            dc.flush

            hash = { 'key1' => 'value1', 'key2' => 'value2', 'key3' => 'value3' }
            dc.set_multi(hash)

            assert_equal 'value1', dc.get('key1')
            assert_equal 'value2', dc.get('key2')
            assert_equal 'value3', dc.get('key3')
          end
        end

        it 'accepts a TTL parameter' do
          memcached_persistent(p) do |dc|
            dc.flush

            hash = { 'ttl_key1' => 'value1', 'ttl_key2' => 'value2' }
            dc.set_multi(hash, 300)

            assert_equal 'value1', dc.get('ttl_key1')
            assert_equal 'value2', dc.get('ttl_key2')
          end
        end

        it 'handles empty hash gracefully' do
          memcached_persistent(p) do |dc|
            # Should not raise
            dc.set_multi({})
          end
        end

        it 'works with complex values' do
          memcached_persistent(p) do |dc|
            dc.flush

            complex_hash = {
              'complex1' => { nested: 'hash', count: 42 },
              'complex2' => [1, 2, 3, 'four'],
              'complex3' => 'simple string'
            }
            dc.set_multi(complex_hash)

            assert_equal({ nested: 'hash', count: 42 }, dc.get('complex1'))
            assert_equal([1, 2, 3, 'four'], dc.get('complex2'))
            assert_equal('simple string', dc.get('complex3'))
          end
        end

        it 'works with raw option' do
          memcached_persistent(p) do |dc|
            dc.flush

            hash = { 'raw_key1' => 'raw_value1', 'raw_key2' => 'raw_value2' }
            dc.set_multi(hash, 300, raw: true)

            assert_equal 'raw_value1', dc.get('raw_key1', raw: true)
            assert_equal 'raw_value2', dc.get('raw_key2', raw: true)
          end
        end
      end

      describe 'delete_multi' do
        it 'deletes multiple keys' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('del_key1', 'value1')
            dc.set('del_key2', 'value2')
            dc.set('del_key3', 'value3')

            assert_equal 'value1', dc.get('del_key1')
            assert_equal 'value2', dc.get('del_key2')
            assert_equal 'value3', dc.get('del_key3')

            dc.delete_multi(%w[del_key1 del_key2 del_key3])

            assert_nil dc.get('del_key1')
            assert_nil dc.get('del_key2')
            assert_nil dc.get('del_key3')
          end
        end

        it 'handles empty array gracefully' do
          memcached_persistent(p) do |dc|
            # Should not raise
            dc.delete_multi([])
          end
        end

        it 'handles non-existent keys gracefully' do
          memcached_persistent(p) do |dc|
            dc.flush

            # Should not raise when deleting keys that do not exist
            dc.delete_multi(%w[nonexistent1 nonexistent2])
          end
        end

        it 'deletes only specified keys' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('keep_key', 'keep_value')
            dc.set('delete_key', 'delete_value')

            dc.delete_multi(['delete_key'])

            assert_equal 'keep_value', dc.get('keep_key')
            assert_nil dc.get('delete_key')
          end
        end
      end
    end
  end
end
