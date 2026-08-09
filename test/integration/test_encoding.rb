# frozen_string_literal: true

require_relative '../helper'

describe 'Encoding' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'supports Unicode values' do
        memcached_persistent(p) do |dc|
          key = 'foo'
          utf8 = 'ƒ©åÍÎ'

          assert dc.set(key, utf8)
          assert_equal utf8, dc.get(key)
        end
      end

      it 'supports Unicode keys' do
        memcached_persistent(p) do |dc|
          utf_key = utf8 = 'ƒ©åÍÎ'

          dc.set(utf_key, utf8)

          assert_equal utf8, dc.get(utf_key)
        end
      end

      # KeyRegularizer.required? previously missed embedded control bytes
      # ('\s' doesn't match NUL or most of the rest of the C0 range), so a key
      # like this went on the wire unencoded -- this proves it now round-trips
      # through the base64 path instead, and (via the sibling key below)
      # doesn't collide with a similar key that has no control byte.
      it 'supports keys with an embedded NUL byte, distinct from a similar key without one' do
        memcached_persistent(p) do |dc|
          nul_key = "foo\x00bar"
          plain_key = 'foobar'

          dc.set(nul_key, 'nul_value')
          dc.set(plain_key, 'plain_value')

          assert_equal 'nul_value', dc.get(nul_key)
          assert_equal 'plain_value', dc.get(plain_key)
        end
      end

      it 'supports keys with a non-NUL control byte (e.g. ESC), distinct from a similar key without one' do
        memcached_persistent(p) do |dc|
          esc_key = "foo\x1Bbar"
          plain_key = 'foobar'

          dc.set(esc_key, 'esc_value')
          dc.set(plain_key, 'plain_value')

          assert_equal 'esc_value', dc.get(esc_key)
          assert_equal 'plain_value', dc.get(plain_key)
        end
      end
    end
  end
end
