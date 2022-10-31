# frozen_string_literal: true

require_relative '../helper'

describe 'concurrent behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'supports multithreaded access' do
        memcached_persistent(p) do |cache|
          cache.flush
          workers = []

          cache.set('f', 'zzz')

          assert op_cas_succeeds((cache.cas('f') do |value|
            value << 'z'
          end))
          assert_equal 'zzzz', cache.get('f')

          # Have a bunch of threads perform a bunch of operations at the same time.
          # Verify the result of each operation to ensure the request and response
          # are not intermingled between threads.
          10.times do
            workers << Thread.new do
              100.times do
                cache.set('a', 9)
                cache.set('b', 11)
                cache.incr('cat', 10, 0, 10)
                cache.set('f', 'zzz')
                res = cache.cas('f') do |value|
                  value << 'z'
                end

                refute_nil res
                refute cache.add('a', 11)
                assert_equal({ 'a' => 9, 'b' => 11 }, cache.get_multi(%w[a b]))
                inc = cache.incr('cat', 10)

                assert_equal 0, inc % 5
                cache.decr('cat', 5)

                assert_equal 11, cache.get('b')

                assert_equal %w[a b], cache.get_multi('a', 'b', 'c').keys.sort
              end
            end
          end

          workers.each(&:join)
          cache.flush
        end
      end
    end
  end
end
