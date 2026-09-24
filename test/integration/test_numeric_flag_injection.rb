# frozen_string_literal: true

require_relative '../helper'

# GHSA-6wmv-xq9m-fmp7: a String numeric argument carrying CRLF must be
# rejected before anything reaches the server, rather than injecting
# additional memcached commands on the connection.
describe 'numeric flag injection' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'rejects an incr/decr default that would inject commands' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('victim', 'role=guest', 0, raw: true)

          overwrite = "1\r\nset victim 0 0 10\r\nrole=ADMIN\r\n"
          flush = "1\r\nflush_all\r\n"
          assert_raises(ArgumentError) { dc.incr('counter', 1, 0, overwrite) }
          assert_raises(ArgumentError) { dc.incr('counter', 1, 0, flush) }
          assert_raises(ArgumentError) { dc.decr('counter', 1, 0, overwrite) }
          assert_raises(ArgumentError) { dc.decr('counter', 1, 0, flush) }

          assert_equal 'role=guest', dc.get('victim', raw: true)
          assert_nil dc.get('counter')
        end
      end

      it 'still accepts an Integer default' do
        memcached_persistent(p) do |dc|
          dc.flush

          assert_equal 5, dc.incr('counter_int', 1, 0, 5)
        end
      end

      it 'keeps the connection usable after rejecting a value' do
        memcached_persistent(p) do |dc|
          dc.flush
          assert_raises(ArgumentError) { dc.incr('counter', 1, 0, "1\r\nflush_all\r\n") }

          dc.set('after', 'ok')

          assert_equal 'ok', dc.get('after')
        end
      end

      next unless p == :meta

      it 'accepts a decimal String default' do
        memcached_persistent(p) do |dc|
          dc.flush

          assert_equal 10, dc.incr('counter_str', 1, 0, '010')
          assert_equal 11, dc.incr('counter_str', 1)
        end
      end
    end
  end
end
