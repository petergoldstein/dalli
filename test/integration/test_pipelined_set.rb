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

      # Each value was looked up by a key rebuilt from the one sent, which
      # missed for a Symbol key or a key too long to send as is, so nil was
      # stored in its place
      describe 'multi-server set_multi keys' do
        it 'stores each value under its key' do
          memcached_persistent(p, 21_345) do |_, port1|
            memcached_persistent(p, 21_346) do |_, port2|
              dc = Dalli::Client.new(["localhost:#{port1}", "localhost:#{port2}"], namespace: 'ns')
              dc.flush
              pairs = Array.new(20) { |i| [:"sym#{i}", "s#{i}"] }.to_h
              pairs.merge!('x' * 300 => 'long', 'é' * 130 => 'long utf-8', "caf\xe9".b => 'binary')

              dc.set_multi(pairs, 0)

              pairs.each { |k, v| assert_equal v, dc.get(k), "key #{k.inspect[0, 20]}" }
            end
          end
        end
      end

      # A value that can't be marshalled, or is over value_max_bytes, must not
      # cost the other keys in the batch: every good key is stored, the bad key
      # is skipped, and the first such error is raised once the batch is done.
      # Single- and multi-server set_multi follow the same contract.
      describe 'with a value that cannot be stored' do
        {
          'an unmarshallable value' => [Dalli::MarshalError, proc {}],
          'a value over value_max_bytes' => [Dalli::ValueOverMaxSize, 'x' * 2048]
        }.each do |label, (error_class, bad_value)|
          it "stores every good key and raises for #{label} on a single server" do
            memcached_persistent(p) do |_, port|
              dc = Dalli::Client.new("localhost:#{port}", protocol: p, value_max_bytes: 1024)
              dc.flush

              good = {}
              20.times { |i| good["good_#{i}"] = "value_#{i}" }

              with_nil_logger do
                assert_raises(error_class) { dc.set_multi(good.merge('bad' => bad_value)) }
              end

              assert_equal good, dc.get_multi(good.keys)
              assert_nil dc.get('bad')
            end
          end

          it "stores every good key and raises for #{label} across servers" do
            port1 = 27_611
            port2 = 27_612
            memcached(p, port1) do
              memcached(p, port2) do
                dc = Dalli::Client.new(["127.0.0.1:#{port1}", "127.0.0.1:#{port2}"], protocol: p, value_max_bytes: 1024)
                dc.flush

                good = {}
                20.times { |i| good["good_#{i}"] = "value_#{i}" }

                with_nil_logger do
                  assert_raises(error_class) { dc.set_multi(good.merge('bad' => bad_value)) }
                end

                assert_equal good, dc.get_multi(good.keys)
                assert_nil dc.get('bad')
              end
            end
          end
        end
      end
    end
  end
end
