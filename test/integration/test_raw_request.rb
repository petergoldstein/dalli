# frozen_string_literal: true

require_relative '../helper'
require 'json'

# A per-request raw: true must return the stored bytes on every read method
# that accepts it, without deserializing (or decompressing) them, even when
# the client itself is not in raw mode.
describe 'per-request raw option' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      let(:payload) { Marshal.dump({ 'secret' => 'value' }) }

      # Stores the payload with the serialized bitflag set, the way a
      # Marshal-serializing client (or an attacker with server access) would.
      def store_serialized(client, key)
        client.set(key, { 'secret' => 'value' })
      end

      it 'returns raw bytes from get and fetch' do
        memcached_persistent(p) do |dc|
          dc.flush
          store_serialized(dc, 'rk')

          assert_equal payload, dc.get('rk', raw: true)
          assert_equal payload, dc.fetch('rk', nil, raw: true)

          # Without the option, values are still deserialized.
          assert_equal({ 'secret' => 'value' }, dc.get('rk'))
        end
      end
    end
  end
end

describe 'Dalli::JSONSerializer' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'round-trips JSON values' do
        memcached(p, 29_199) do |_dc, port|
          dc = Dalli::Client.new("127.0.0.1:#{port}", serializer: Dalli::JSONSerializer, protocol: p)
          value = { 'a' => [1, 2.5, true, nil], 'b' => 'str' }
          dc.set('jk', value)

          assert_equal value, dc.get('jk')
        end
      end

      it 'never creates objects from a stored json_class' do
        memcached(p, 29_199) do |_dc, port|
          dc = Dalli::Client.new("127.0.0.1:#{port}", serializer: Dalli::JSONSerializer, protocol: p)
          stored = { 'json_class' => 'Range', 'a' => [1, 2, false] }
          dc.set('jk', stored)

          assert_equal stored, dc.get('jk')
        end
      end
    end
  end
end
