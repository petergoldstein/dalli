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

    should 'raise when no servers are available/ defined' do
      ring = Dalli::Ring.new([], {})
      message = assert_raise Dalli::NetworkError do
        ring.server_for_key('test')
      end
      assert_equal "No server available", message
    end

    context 'containing only a single server' do
      should "raise correctly when it's not alive" do
        servers = [
          Dalli::Server.new("localhost:12345"),
        ]
        ring = Dalli::Ring.new(servers, {})
        message = assert_raise Dalli::NetworkError do
          ring.server_for_key('test')
        end
        assert_equal "No server available", message
      end

      should "return the server when it's alive" do
        servers = [
          Dalli::Server.new("localhost:19122"),
        ]
        ring = Dalli::Ring.new(servers, {})
        memcached do |cache|
          ring = cache.send(:ring)
          assert_same ring.servers.first, ring.server_for_key('test')
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
        message = assert_raise Dalli::NetworkError do
          ring.server_for_key('test')
        end
        assert_equal "No server available", message
      end

      should "return an alive server when at least one is alive" do
        servers = [
          Dalli::Server.new("localhost:12346"),
          Dalli::Server.new("localhost:19122"),
        ]
        ring = Dalli::Ring.new(servers, {})
        memcached do |cache|
          ring = cache.send(:ring)
          assert_same ring.servers.first, ring.server_for_key('test')
        end
      end
    end
  end
end
