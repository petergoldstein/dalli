# frozen_string_literal: true

require_relative '../helper'
require 'json'

# A per-request raw: true must return the stored bytes on every read method,
# without deserializing (or decompressing) them, even when the client itself
# is not in raw mode.
describe 'per-request raw option' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      let(:payload) { Marshal.dump({ 'secret' => 'value' }) }

      # Stores the payload with the serialized bitflag set, the way a
      # Marshal-serializing client (or an attacker with server access) would.
      def store_serialized(client, key)
        client.set(key, { 'secret' => 'value' })
      end

      it 'returns raw bytes from get, get_cas, get_with_metadata and fetch' do
        memcached_persistent(p) do |dc|
          dc.flush
          store_serialized(dc, 'rk')

          assert_equal payload, dc.get('rk', raw: true)
          assert_equal payload, dc.get_cas('rk', raw: true).first
          assert_equal payload, dc.get_with_metadata('rk', raw: true)[:value]
          assert_equal payload, dc.fetch('rk', nil, raw: true)

          # Without the option, values are still deserialized.
          assert_equal({ 'secret' => 'value' }, dc.get_cas('rk').first)
          assert_equal({ 'secret' => 'value' }, dc.get_with_metadata('rk')[:value])
        end
      end

      it 'returns raw bytes from the multi-get methods on a single server' do
        memcached_persistent(p) do |dc|
          dc.flush
          store_serialized(dc, 'rk1')
          store_serialized(dc, 'rk2')

          assert_equal({ 'rk1' => payload, 'rk2' => payload }, dc.get_multi('rk1', 'rk2', req_options: { raw: true }))
          assert_equal [payload, payload],
                       dc.get_multi_cas('rk1', 'rk2', req_options: { raw: true }).values.map(&:first)
          assert_equal([payload, payload],
                       dc.get_multi_with_metadata('rk1', 'rk2', req_options: { raw: true }).values.map { _1[:value] })

          assert_equal({ 'secret' => 'value' }, dc.get_multi('rk1', 'rk2')['rk1'])
        end
      end

      it 'returns raw bytes from the multi-get methods across servers' do
        memcached_persistent(p, 21_347) do |_, port1|
          memcached_persistent(p, 21_348) do |_, port2|
            dc = Dalli::Client.new(["localhost:#{port1}", "localhost:#{port2}"])
            dc.flush
            keys = Array.new(20) { |i| "rk#{i}" }
            keys.each { |k| store_serialized(dc, k) }

            assert_equal(keys.to_h { |k| [k, payload] }, dc.get_multi(keys, req_options: { raw: true }))
            assert_equal [payload] * keys.size,
                         dc.get_multi_cas(*keys, req_options: { raw: true }).values.map(&:first)
            assert_equal([payload] * keys.size,
                         dc.get_multi_with_metadata(*keys, req_options: { raw: true }).values.map { |h| h[:value] })

            assert_equal({ 'secret' => 'value' }, dc.get_multi(keys)['rk0'])
          end
        end
      end

      describe 'with values above the compression threshold' do
        let(:big) { 'x' * 5000 }

        it 'round-trips through set and get' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('rbig', big, 0, raw: true)

            assert_equal big, dc.get('rbig', raw: true)
          end
        end

        it 'round-trips through set and get_multi' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('rbig', big, 0, raw: true)

            assert_equal({ 'rbig' => big }, dc.get_multi('rbig', req_options: { raw: true }))
          end
        end

        it 'round-trips through set_multi and get_multi' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set_multi({ 'rbig1' => big, 'rbig2' => big }, 0, raw: true)

            assert_equal({ 'rbig1' => big, 'rbig2' => big },
                         dc.get_multi('rbig1', 'rbig2', req_options: { raw: true }))
          end
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
          dc = Dalli::Client.new("127.0.0.1:#{port}", serializer: Dalli::JSONSerializer)
          value = { 'a' => [1, 2.5, true, nil], 'b' => 'str' }
          dc.set('jk', value)

          assert_equal value, dc.get('jk')
        end
      end

      it 'never creates objects from a stored json_class' do
        memcached(p, 29_199) do |_dc, port|
          dc = Dalli::Client.new("127.0.0.1:#{port}", serializer: Dalli::JSONSerializer)
          stored = { 'json_class' => 'Range', 'a' => [1, 2, false] }
          dc.set('jk', stored)

          assert_equal stored, dc.get('jk')
        end
      end
    end
  end
end
