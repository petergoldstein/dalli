# frozen_string_literal: true

require_relative 'helper'

class TestServer
  attr_reader :name

  def initialize(attribs, _client_options = {})
    @name = attribs
  end

  def weight
    1
  end
end

describe 'Ring' do
  describe 'a ring of servers' do
    it 'have the continuum sorted by value' do
      servers = ['localhost:11211', 'localhost:9500']
      ring = Dalli::Ring.new(servers, TestServer, {})
      previous_value = 0
      ring.continuum.each do |entry|
        assert entry.value > previous_value
        previous_value = entry.value
      end
    end

    it 'raise when no servers are available/defined' do
      ring = Dalli::Ring.new([], TestServer, {})
      assert_raises Dalli::RingError, message: 'No server available' do
        ring.server_for_key('test')
      end
    end

    describe 'containing only a single server' do
      it "raise correctly when it's not alive" do
        servers = ['localhost:12345']
        ring = Dalli::Ring.new(servers, Dalli::Protocol::Binary, {})
        assert_raises Dalli::RingError, message: 'No server available' do
          ring.server_for_key('test')
        end
      end

      it "return the server when it's alive" do
        servers = ['localhost:19191']
        ring = Dalli::Ring.new(servers, Dalli::Protocol::Binary, {})
        memcached(:binary, 19_191) do |mc|
          ring = mc.send(:ring)

          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    describe 'containing multiple servers' do
      it 'raise correctly when no server is alive' do
        servers = ['localhost:12345', 'localhost:12346']
        ring = Dalli::Ring.new(servers, Dalli::Protocol::Binary, {})
        assert_raises Dalli::RingError, message: 'No server available' do
          ring.server_for_key('test')
        end
      end

      it 'return an alive server when at least one is alive' do
        servers = ['localhost:12346', 'localhost:19191']
        ring = Dalli::Ring.new(servers, Dalli::Protocol::Binary, {})
        memcached(:binary, 19_191) do |mc|
          ring = mc.send(:ring)

          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    it 'detect when a dead server is up again' do
      memcached(:binary, 19_997) do
        down_retry_delay = 0.5
        dc = Dalli::Client.new(['localhost:19997', 'localhost:19998'], down_retry_delay: down_retry_delay)

        assert_equal 1, dc.stats.values.compact.count

        memcached(:binary, 19_998) do
          assert_equal 2, dc.stats.values.compact.count
        end
      end
    end
  end
end
