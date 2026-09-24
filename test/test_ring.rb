# frozen_string_literal: true

require_relative 'helper'

describe 'Ring' do
  describe 'alive? checks' do
    # Counts alive? calls instead of touching the network
    def counting_ring(alive: true)
      ring = Dalli::Ring.new(['localhost:12345', 'localhost:12346'], {})
      calls = Hash.new(0)
      ring.servers.each do |server|
        server.define_singleton_method(:alive?) do
          calls[server] += 1
          alive
        end
      end
      [ring, calls]
    end

    it 'checks each server once when grouping many keys' do
      ring, calls = counting_ring
      keys = Array.new(200) { |i| "key#{i}" }

      groups = ring.keys_grouped_by_server(keys)

      assert_equal 2, groups.size
      assert_equal 200, groups.values.sum(&:size)
      assert_equal [1, 1], calls.values
    end

    it 'checks the chosen server once per single-key lookup' do
      ring, calls = counting_ring

      ring.server_for_key('test')

      assert_equal 1, calls.values.sum
    end

    it 'groups keys under nil when no server is alive' do
      ring, = counting_ring(alive: false)

      assert_equal({ nil => %w[a b] }, ring.keys_grouped_by_server(%w[a b]))
    end
  end

  describe 'a ring of servers' do
    it 'have the continuum sorted by value' do
      servers = ['localhost:11211', 'localhost:9500']
      ring = Dalli::Ring.new(servers, {})
      previous_value = 0
      ring.continuum.each do |entry|
        assert_operator entry.value, :>, previous_value
        previous_value = entry.value
      end
    end

    it 'raise when no servers are available/defined' do
      ring = Dalli::Ring.new([], {})
      assert_error Dalli::RingError, /No server available/ do
        ring.server_for_key('test')
      end
    end

    describe 'containing only a single server' do
      it "raise correctly when it's not alive" do
        servers = ['localhost:12345']
        ring = Dalli::Ring.new(servers, {})
        assert_error Dalli::RingError, /No server available/ do
          ring.server_for_key('test')
        end
      end

      it "return the server when it's alive" do
        memcached(:meta, 19_191) do |mc|
          ring = mc.send(:ring)

          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    describe 'containing multiple servers' do
      it 'raise correctly when no server is alive' do
        servers = ['localhost:12345', 'localhost:12346']
        ring = Dalli::Ring.new(servers, {})
        assert_error Dalli::RingError, /No server available/ do
          ring.server_for_key('test')
        end
      end

      it 'return an alive server when at least one is alive' do
        memcached(:meta, 19_191) do |mc|
          ring = mc.send(:ring)

          assert_predicate ring.server_for_key('test'), :alive?
        end
      end
    end

    it 'detect when a dead server is up again' do
      memcached(:meta, 19_997) do
        # A non-zero delay would make this test's timing race against how
        # long the second memcached process takes to spawn -- alive? now
        # correctly engages the down-state cooldown (see
        # Dalli::Protocol::Base#alive?), so a real delay would sometimes
        # still be in its cooldown window when the second assertion runs.
        down_retry_delay = 0
        dc = Dalli::Client.new(['localhost:19997', 'localhost:19998'], down_retry_delay: down_retry_delay)

        assert_equal 1, dc.stats.values.compact.count

        memcached(:meta, 19_998) do
          assert_equal 2, dc.stats.values.compact.count
        end
      end
    end
  end
end
