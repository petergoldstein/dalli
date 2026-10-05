# frozen_string_literal: true

require_relative '../helper'

describe 'set_multi' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      # Binary set_multi used to wait for a reply to each quiet setq, which
      # memcached never sends, so it timed out without storing anything
      it 'stores every value and leaves the connection ready for the next request' do
        memcached_persistent(p) do |dc|
          dc.flush
          pairs = Array.new(500) { |i| ["sm:#{i}", "value-#{i}"] }.to_h

          dc.set_multi(pairs, 0)

          assert_equal pairs, dc.get_multi(pairs.keys)
          assert dc.set('after', 'ok')
          assert_equal 'ok', dc.get('after')
        end
      end

      it 'returns promptly' do
        memcached_persistent(p) do |dc|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dc.set_multi({ 'a' => '1', 'b' => '2' }, 0)

          assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
        end
      end
    end
  end
end
