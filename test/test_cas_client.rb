# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli::Cas::Client' do
  describe 'using a live server' do
    it 'supports get with CAS' do
      memcached_persistent do |dc|
        dc.flush

        expected = { 'blah' => 'blerg!' }
        get_block_called = false
        stored_value = stored_cas = nil
        # Validate call-with-block
        dc.get_cas('gets_key') do |v, cas|
          get_block_called = true
          stored_value = v
          stored_cas = cas
        end
        assert get_block_called
        assert_nil stored_value

        dc.set('gets_key', expected)

        # Validate call-with-return-value
        stored_value, stored_cas = dc.get_cas('gets_key')
        assert_equal stored_value, expected
        refute_equal(stored_cas, 0)
      end
    end

    it 'supports multi-get with CAS' do
      memcached_persistent do |dc|
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
      memcached_persistent do |dc|
        dc.flush
        cas = dc.set('key', 'value')

        # Accepts CAS, replaces, and returns new CAS
        cas = dc.replace_cas('key', 'value2', cas)
        assert cas.is_a?(Integer)

        assert_equal 'value2', dc.get('key')
      end
    end

    it 'supports delete with CAS' do
      memcached_persistent do |dc|
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
      memcached_persistent do |dc|
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
end
