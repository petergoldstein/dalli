# frozen_string_literal: true

require_relative '../helper'
require 'json'

describe 'Serializer configuration' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'does not allow values over the 1MB limit' do
        memcached_persistent(p) do |dc|
          value = SecureRandom.random_bytes((1024 * 1024) + 30_000)

          with_nil_logger do
            assert_raises Dalli::ValueOverMaxSize do
              dc.set('verylarge', value)
            end
          end
        end
      end

      it 'raises ValueOverMaxSize for a value that fits only without the key and item header' do
        memcached_persistent(p) do |dc|
          value = 'x' * 1024 * 1024

          with_nil_logger do
            assert_raises Dalli::ValueOverMaxSize do
              dc.set('verylarge', value, nil, raw: true, compress: false)
            end
          end
        end
      end

      it 'stores the largest value that the item size limit allows' do
        memcached_persistent(p) do |dc|
          key = 'verylarge'
          overhead = Dalli::Protocol::ValueMarshaller::ITEM_OVERHEAD_BYTES
          value = 'x' * ((1024 * 1024) - key.bytesize - overhead)

          assert dc.set(key, value, nil, raw: true, compress: false)
          assert_equal value, dc.get(key, raw: true)
        end
      end

      it 'allow large values under the limit to be set' do
        memcached_persistent(p) do |dc|
          value = '0' * 1024 * 1024

          assert dc.set('verylarge', value, nil, compress: true)
        end
      end

      it 'errors appropriately when the value cannot be marshalled' do
        memcached_persistent(p) do |dc|
          with_nil_logger do
            assert_raises Dalli::MarshalError do
              dc.set('a', proc { true })
            end
          end
        end
      end
    end
  end
end
