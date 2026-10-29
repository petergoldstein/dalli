# frozen_string_literal: true

require_relative '../helper'

describe 'Namespace and key behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'handles namespaced keys' do
        memcached_persistent(p) do |_, port|
          dc = Dalli::Client.new("localhost:#{port}", namespace: 'a')
          dc.set('namespaced', 1)
          dc2 = Dalli::Client.new("localhost:#{port}", namespace: 'b')
          dc2.set('namespaced', 2)

          assert_equal 1, dc.get('namespaced')
          assert_equal 2, dc2.get('namespaced')
        end
      end

      it 'handles a nil namespace' do
        memcached_persistent(p) do |_, port|
          dc = Dalli::Client.new("localhost:#{port}", namespace: nil)
          dc.set('key', 1)

          assert_equal 1, dc.get('key')
        end
      end

      it 'truncates cache keys that are too long' do
        memcached_persistent(p) do |_, port|
          dc = Dalli::Client.new("localhost:#{port}", namespace: 'some:namspace')
          key = 'this-cache-key-is-far-too-long-so-it-must-be-hashed-and-truncated-and-stuff' * 10
          value = 'some value'

          assert op_addset_succeeds(dc.set(key, value))
          assert_equal value, dc.get(key)
        end
      end

      it 'handles namespaced keys in get_multi' do
        memcached_persistent(p) do |_, port|
          dc = Dalli::Client.new("localhost:#{port}", namespace: 'a')
          dc.set('a', 1)
          dc.set('b', 2)

          assert_equal({ 'a' => 1, 'b' => 2 }, dc.get_multi('a', 'b'))
        end
      end

      it 'handles special Regexp characters in namespace with get_multi' do
        memcached_persistent(p) do |_, port|
          # /(?!)/ is a contradictory PCRE and should never be able to match
          dc = Dalli::Client.new("localhost:#{port}", namespace: '(?!)')
          dc.set('a', 1)
          dc.set('b', 2)

          assert_equal({ 'a' => 1, 'b' => 2 }, dc.get_multi('a', 'b'))
        end
      end

      it 'allows whitespace characters in keys' do
        memcached_persistent(p) do |dc|
          dc.set "\t", 1

          assert_equal 1, dc.get("\t")
          dc.set "\n", 1

          assert_equal 1, dc.get("\n")
          dc.set '   ', 1

          assert_equal 1, dc.get('   ')
        end
      end

      it 'does not allow blanks for keys' do
        memcached_persistent(p) do |dc|
          assert_raises ArgumentError do
            dc.set '', 1
          end
          assert_raises ArgumentError do
            dc.set nil, 1
          end
        end
      end

      it 'allow the namespace to be a symbol' do
        memcached_persistent(p) do |_, port|
          dc = Dalli::Client.new("localhost:#{port}", namespace: :wunderschoen)
          dc.set 'x' * 251, 1

          assert_equal(1, dc.get(('x' * 251).to_s))
        end
      end

      # Replies name the key as sent, so a multi-get used to strip the
      # namespace from it to get back to the caller's key. That raised
      # ArgumentError for a key that isn't valid UTF-8, failing the whole call,
      # returned a digested key in place of a long one, and tagged binary keys
      # as UTF-8.
      describe 'multi-get result keys with a namespace' do
        Minitest::Spec::MULTI_GETS.each do |name, multi_get|
          it "#{name} returns binary keys that aren't valid UTF-8 under the caller's keys" do
            with_one_and_two_servers(p, namespace: 'ns') do |dc|
              expected = { 'a' => 1, "\xff".b => 2, "caf\xe9".b => 3 }
              expected.each { |k, v| dc.set(k, v) }

              assert_caller_keys expected, multi_get.call(dc, expected.keys)
            end
          end

          it "#{name} returns keys too long to send as is under the caller's keys" do
            with_one_and_two_servers(p, namespace: 'ns') do |dc|
              expected = { 'x' * 300 => 1, 'é' * 130 => 2, 'short' => 3 }
              expected.each { |k, v| dc.set(k, v) }

              assert_caller_keys expected, multi_get.call(dc, expected.keys)
            end
          end

          it "#{name} returns one entry for a key given more than once" do
            with_one_and_two_servers(p, namespace: 'ns') do |dc|
              dc.set('a', 1)
              dc.set("\xff".b, 2)

              assert_caller_keys({ 'a' => 1, "\xff".b => 2 }, multi_get.call(dc, ['a', "\xff".b, 'a', "\xff".b]))
            end
          end
        end
      end
    end
  end
end
