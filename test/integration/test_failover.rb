# frozen_string_literal: true

require_relative '../helper'

describe 'failover' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      # Timeouts on JRuby work differently and aren't firing, meaning we're
      # not testing the condition
      unless defined? JRUBY_VERSION
        describe 'timeouts' do
          it 'not lead to corrupt sockets' do
            memcached_persistent(p) do |dc|
              value = { test: '123' }
              begin
                Timeout.timeout 0.01 do
                  start_time = Time.now
                  10_000.times do
                    dc.set('test_123', value)
                  end

                  flunk("Did not timeout in #{Time.now - start_time}")
                end
              rescue Timeout::Error
                # Ignore expected timeout
              end

              assert_equal(value, dc.get('test_123'))
            end
          end
        end
      end

      describe 'assuming some bad servers' do
        it 'silently reconnect if server hiccups' do
          memcached_persistent(p, find_available_port) do |dc, port|
            dc.set 'foo', 'bar'
            foo = dc.get 'foo'

            assert_equal('bar', foo)

            memcached_kill(port)
            memcached_persistent(p, port) do
              foo = dc.get 'foo'

              assert_nil foo

              memcached_kill(port)
            end
          end
        end

        it 'reconnects if server idles the connection' do
          memcached(p, find_available_port, '-o idle_timeout=1') do |_, first_port|
            memcached(p, find_available_port, '-o idle_timeout=1') do |_, second_port|
              dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
              dc.set 'foo', 'bar'
              dc.set 'foo2', 'bar2'
              foo = dc.get_multi 'foo', 'foo2'

              assert_equal({ 'foo' => 'bar', 'foo2' => 'bar2' }, foo)

              # wait for socket to expire and get cleaned up
              sleep 5

              foo = dc.get_multi 'foo', 'foo2'

              assert_equal({ 'foo' => 'bar', 'foo2' => 'bar2' }, foo)
            end
          end
        end

        it 'handle graceful failover' do
          memcached_persistent(p, find_available_port) do |_first_dc, first_port|
            memcached_persistent(p, find_available_port) do |_second_dc, second_port|
              dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
              dc.set 'foo', 'bar'
              foo = dc.get 'foo'

              assert_equal('bar', foo)

              memcached_kill(first_port)

              dc.set 'foo', 'bar'
              foo = dc.get 'foo'

              assert_equal('bar', foo)

              memcached_kill(second_port)

              assert_raises Dalli::RingError, message: 'No server available' do
                dc.set 'foo', 'bar'
              end
            end
          end
        end

        it 'handle them gracefully in get_multi' do
          memcached_persistent(p, find_available_port) do |_first_dc, first_port|
            memcached(p, find_available_port) do |_second_dc, second_port|
              dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
              dc.set 'a', 'a1'
              result = dc.get_multi ['a']

              assert_equal({ 'a' => 'a1' }, result)

              memcached_kill(first_port)

              result = dc.get_multi ['a']

              assert_equal({ 'a' => 'a1' }, result)
            end
          end
        end

        it 'handle graceful failover in get_multi' do
          memcached_persistent(p, find_available_port) do |_first_dc, first_port|
            memcached_persistent(p, find_available_port) do |_second_dc, second_port|
              dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
              dc.set 'foo', 'foo1'
              dc.set 'bar', 'bar1'
              result = dc.get_multi %w[foo bar]

              assert_equal({ 'foo' => 'foo1', 'bar' => 'bar1' }, result)

              memcached_kill(first_port)

              dc.set 'foo', 'foo1'
              dc.set 'bar', 'bar1'
              result = dc.get_multi %w[foo bar]

              assert_equal({ 'foo' => 'foo1', 'bar' => 'bar1' }, result)

              memcached_kill(second_port)

              result = dc.get_multi %w[foo bar]

              assert_empty(result)
            end
          end
        end

        it 'stats it still properly report' do
          memcached_persistent(p, find_available_port) do |_first_dc, first_port|
            memcached_persistent(p, find_available_port) do |_second_dc, second_port|
              dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
              result = dc.stats

              assert_instance_of Hash, result["localhost:#{first_port}"]
              assert_instance_of Hash, result["localhost:#{second_port}"]

              memcached_kill(first_port)

              dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
              result = dc.stats

              assert_instance_of NilClass, result["localhost:#{first_port}"]
              assert_instance_of Hash, result["localhost:#{second_port}"]

              memcached_kill(second_port)
            end
          end
        end
      end
    end
  end
end
