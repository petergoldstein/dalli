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
      # like this went on the wire unencoded. This doesn't prove base64
      # encoding is actually used on the wire -- real memcached's key
      # tokenizer splits on whitespace, not other control bytes, so it parses
      # such a key as ordinary content either way, and the unit-level tests in
      # test_key_regularizer.rb / test_request_formatter.rb are what actually
      # exercise the encoding path. This is an end-to-end functional check:
      # such a key can still be set/get correctly, and (via the sibling key
      # below) doesn't collide with a similar key that has no control byte.
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

      # A base64-encoded reply key is decoded as UTF-8, so a binary key used
      # to come back as a UTF-8 String that isn't a key of the result's
      Minitest::Spec::MULTI_GETS.each do |name, multi_get|
        it "#{name} returns binary and Unicode keys with the caller's encoding" do
          with_one_and_two_servers(p) do |dc|
            expected = { "\xff".b => 1, "caf\xe9".b => 2, 'café' => 3, 'é' * 130 => 4, 'ascii'.b => 5 }
            expected.each { |k, v| dc.set(k, v) }

            assert_caller_keys expected, multi_get.call(dc, expected.keys)
          end
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

      it 'appends and prepends UTF-16 values as their bytes' do
        memcached_persistent(p) do |dc|
          dc.set('k', 'x', 0, raw: true)

          assert dc.append('k', 'a'.encode('UTF-16LE'))
          assert dc.prepend('k', 'p'.encode('UTF-32LE'))
          assert_equal "p\0\0\0xa\0".b, dc.get('k', raw: true).b
        end
      end

      it 'set_multi stores UTF-8, binary and UTF-16 values together' do
        with_one_and_two_servers(p) do |dc|
          values = { 'utf8' => 'café', 'binary' => "\xff\xfe".b, 'utf16' => 'hé'.encode('UTF-16LE') }
          dc.set_multi(values, 0, raw: true)

          values.each { |k, v| assert_equal v.b, dc.get(k, raw: true).b, k }
        end
      end
    end
  end
end
