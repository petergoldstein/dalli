require 'helper'

class TestRing < Test::Unit::TestCase

  context 'a ring of servers' do

    should "have the continuum sorted by value" do
      servers = [stub(:hostname => "localhost", :port => "11211", :weight => 1),
                 stub(:hostname => "localhost", :port => "9500", :weight => 1)]
      ring = Dalli::Ring.new(servers, {})
      previous_value = 0
      ring.continuum.each do |entry|
        assert entry.value > previous_value
        previous_value = entry.value
      end
    end

    should 'raise when no servers are available/defined' do
      ring = Dalli::Ring.new([], {})
      assert_raise Dalli::RingError, :message => "No server available" do
        ring.server_for_key('test')
      end
    end

    context 'containing only a single server' do
      should "raise correctly when it's not alive" do
        servers = [
          Dalli::Server.new("localhost:12345"),
        ]
        ring = Dalli::Ring.new(servers, {})
        assert_raise Dalli::RingError, :message => "No server available" do
          ring.server_for_key('test')
        end
      end

      should "return the server when it's alive" do
        servers = [
          Dalli::Server.new("localhost:19191"),
        ]
        ring = Dalli::Ring.new(servers, {})
        memcached(19191) do |mc|
          ring = mc.send(:ring)
          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    context 'containing multiple servers' do
      should "raise correctly when no server is alive" do
        servers = [
          Dalli::Server.new("localhost:12345"),
          Dalli::Server.new("localhost:12346"),
        ]
        ring = Dalli::Ring.new(servers, {})
        assert_raise Dalli::RingError, :message => "No server available" do
          ring.server_for_key('test')
        end
      end

      should "return an alive server when at least one is alive" do
        servers = [
          Dalli::Server.new("localhost:12346"),
          Dalli::Server.new("localhost:19191"),
        ]
        ring = Dalli::Ring.new(servers, {})
        memcached(19191) do |mc|
          ring = mc.send(:ring)
          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    should 'detect when a dead server is up again' do
      memcached(29125) do
        down_retry_delay = 0.5
        dc = Dalli::Client.new(['localhost:29125', 'localhost:29126'], :down_retry_delay => down_retry_delay)
        assert_equal 1, dc.stats.values.compact.count

        memcached(29126) do
          assert_equal 1, dc.stats.values.compact.count
         
          sleep(down_retry_delay+0.1)

          assert_equal 2, dc.stats.values.compact.count
        end
      end
    end
  end
end
