require 'helper'

describe 'failover' do

  describe 'timeouts' do
    it 'not lead to corrupt sockets' do
      memcached_persistent do |dc|
        value = {:test => "123"}
        begin
          Timeout.timeout 0.01 do
            start_time = Time.now
            10_000.times do
              dc.set("test_123", value)
            end
            flunk("Did not timeout in #{Time.now - start_time}")
          end
        rescue Timeout::Error
        end

        assert_equal(value, dc.get("test_123"))
      end
    end
  end


  describe 'assuming some bad servers' do

    it 'silently reconnect if server hiccups' do
      server_port = 30124
      memcached_persistent(server_port) do |dc, port|
        dc.set 'foo', 'bar'
        foo = dc.get 'foo'
        assert_equal foo, 'bar'

        memcached_kill(port)
        memcached_persistent(port) do

          foo = dc.get 'foo'
          assert_nil foo

          memcached_kill(port)
        end
      end
    end

    it 'handle graceful failover' do
      port_1 = 31777
      port_2 = 32113
      memcached_persistent(port_1) do |first_dc, first_port|
        memcached_persistent(port_2) do |second_dc, second_port|
          dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
          dc.set 'foo', 'bar'
          foo = dc.get 'foo'
          assert_equal foo, 'bar'

          memcached_kill(first_port)

          dc.set 'foo', 'bar'
          foo = dc.get 'foo'
          assert_equal foo, 'bar'

          memcached_kill(second_port)

          assert_raises Dalli::RingError, :message => "No server available" do
            dc.set 'foo', 'bar'
          end
        end
      end
    end

    it 'handle them gracefully in get_multi' do
      port_1 = 32971
      port_2 = 34312
      memcached_persistent(port_1) do |first_dc, first_port|
        memcached(port_2) do |second_dc, second_port|
          dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
          dc.set 'a', 'a1'
          result = dc.get_multi ['a']
          assert_equal result, {'a' => 'a1'}

          memcached_kill(first_port)

          result = dc.get_multi ['a']
          assert_equal result, {'a' => 'a1'}
        end
      end
    end

    it 'handle graceful failover in get_multi' do
      port_1 = 34541
      port_2 = 33044
      memcached_persistent(port_1) do |first_dc, first_port|
        memcached_persistent(port_2) do |second_dc, second_port|
          dc = Dalli::Client.new ["localhost:#{first_port}", "localhost:#{second_port}"]
          dc.set 'foo', 'foo1'
          dc.set 'bar', 'bar1'
          result = dc.get_multi ['foo', 'bar']
          assert_equal result, {'foo' => 'foo1', 'bar' => 'bar1'}

          memcached_kill(first_port)

          dc.set 'foo', 'foo1'
          dc.set 'bar', 'bar1'
          result = dc.get_multi ['foo', 'bar']
          assert_equal result, {'foo' => 'foo1', 'bar' => 'bar1'}

          memcached_kill(second_port)

          result = dc.get_multi ['foo', 'bar']
          assert_equal result, {}
        end
      end
    end

    it 'stats it still properly report' do
      port_1 = 34547
      port_2 = 33219
      memcached_persistent(port_1) do |first_dc, first_port|
        memcached_persistent(port_2) do |second_dc, second_port|
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
