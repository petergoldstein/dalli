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

      # memcached stores bytes, so a raw value in an encoding that isn't
      # ASCII-compatible is stored as its bytes rather than raising
      # Encoding::CompatibilityError
      it 'stores raw UTF-16 values as their bytes' do
        memcached_persistent(p) do |dc|
          utf16 = 'hé'.encode('UTF-16LE')

          assert dc.set('utf16', utf16, 0, raw: true)
          assert_equal utf16.b, dc.get('utf16', raw: true).b

          dc.quiet { dc.set('quiet_utf16', utf16, 0, raw: true) }

          assert_equal utf16.b, dc.get('quiet_utf16', raw: true).b
        end
      end

      # The encoding error used to close the connection, dropping the quiet
      # writes buffered before it
      it 'keeps earlier quiet writes when a later value is UTF-16' do
        memcached_persistent(p) do |dc|
          dc.quiet do
            dc.set('before', '1', 0, raw: true)
            dc.set('utf16', 'x'.encode('UTF-16LE'), 0, raw: true)
            dc.set('after', '3', 0, raw: true)
          end

          assert_equal '1', dc.get('before', raw: true)
          assert_equal 'x'.encode('UTF-16LE').b, dc.get('utf16', raw: true).b
          assert_equal '3', dc.get('after', raw: true)
        end
      end

      it 'appends and prepends UTF-16 values as their bytes' do
        memcached_persistent(p) do |dc|
          dc.set('k', 'x', 0, raw: true)

          assert dc.append('k', 'a'.encode('UTF-16LE'))
          assert dc.prepend('k', 'p'.encode('UTF-32LE'))
          assert_equal "p\0\0\0xa\0".b, dc.get('k', raw: true).b
        end
      end

      it 'set_multi stores UTF-8, binary and UTF-16 values together' do
        memcached_persistent(p) do |dc|
          values = { 'utf8' => 'café', 'binary' => "\xff\xfe".b, 'utf16' => 'hé'.encode('UTF-16LE') }
          dc.set_multi(values, 0, raw: true)

          values.each { |k, v| assert_equal v.b, dc.get(k, raw: true).b, k }
        end
      end
    end
  end
end
