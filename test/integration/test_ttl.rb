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
    end
  end
end
