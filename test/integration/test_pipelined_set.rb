# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Set' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'single-server set_multi fast path' do
        it 'sets multiple key-value pairs' do
          memcached_persistent(p) do |dc|
            dc.flush

            hash = { 'a' => 'foo', 'b' => 123, 'c' => %w[x y z] }
            dc.set_multi(hash)

            assert_equal 'foo', dc.get('a')
            assert_equal 123, dc.get('b')
            assert_equal %w[x y z], dc.get('c')
          end
        end

        it 'sets with custom TTL' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set_multi({ 'ttl1' => 'val1', 'ttl2' => 'val2' }, 300)

            assert_equal 'val1', dc.get('ttl1')
            assert_equal 'val2', dc.get('ttl2')
          end
        end

        it 'sets with raw mode' do
          memcached_persistent(p, 21_345, '', raw: true) do |dc|
            dc.flush

            dc.set_multi({ 'r1' => 'raw_val1', 'r2' => 'raw_val2' }, 300)

            assert_equal 'raw_val1', dc.get('r1')
            assert_equal 'raw_val2', dc.get('r2')
          end
        end

        it 'handles empty hash' do
          memcached_persistent(p) do |dc|
            dc.set_multi({})
          end
        end

        it 'handles large batch' do
          memcached_persistent(p) do |dc|
            dc.flush

            hash = {}
            100.times { |i| hash["bulk_#{i}"] = "value_#{i}" }
            dc.set_multi(hash)

            assert_equal 'value_0', dc.get('bulk_0')
            assert_equal 'value_99', dc.get('bulk_99')
          end
        end

        it 'works with get_multi round-trip' do
          memcached_persistent(p) do |dc|
            dc.flush

            hash = { 'rt1' => 'v1', 'rt2' => 'v2', 'rt3' => 'v3' }
            dc.set_multi(hash)
            result = dc.get_multi(%w[rt1 rt2 rt3 rt4])

            assert_equal hash, result
          end
        end
      end
    end
  end
end
