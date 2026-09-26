# frozen_string_literal: true

require_relative '../helper'

describe 'defer_drain behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      # Builds a persistent client configured with defer_drain: true.
      def with_deferred_client(protocol)
        memcached_persistent(protocol, 21_345, '', { defer_drain: true }) do |dc|
          dc.close
          dc.flush
          yield dc
        end
      end

      # Wraps each server's noop barrier with a counter so we can assert how many
      # round-trips a pipelined operation actually performs.
      def count_noop_barriers(client)
        counts = Hash.new(0).compare_by_identity
        client.send(:ring).servers.each do |server|
          server.define_singleton_method(:write_noop) do
            counts[self] += 1
            super()
          end
        end
        counts
      end

      # The first "<prefix><n>" key that the ring maps to server
      def key_on(client, server, prefix)
        (1..).lazy.map { |i| "#{prefix}#{i}" }.find { |k| client.send(:ring).server_for_key(k) == server }
      end

      it 'defers the drain for quiet writes and reconciles before the next read' do
        with_deferred_client(p) do |dc|
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)

          dc.quiet do
            # Quiet writes still return nil
            assert_nil dc.set(key, value)
          end

          # The mutation was sent eagerly, so the value is present; the read
          # transparently reconciles the pending quiet response first.
          assert_equal value, dc.get(key)
        end
      end

      it 'coalesces many quiet mutations across separate quiet blocks' do
        with_deferred_client(p) do |dc|
          pairs = Array.new(25) { [SecureRandom.hex(4), SecureRandom.hex(4)] }

          # Each mutation is wrapped in its own quiet block (mirroring the
          # per-op quiet wrapper used in production). None should block on a
          # response; the single get below reconciles them all.
          pairs.each do |k, v|
            dc.quiet { assert_nil dc.set(k, v) }
          end

          # Read back in a separate pass to prove the writes were not lost while
          # their drains were deferred.
          pairs.each do |k, v| # rubocop:disable Style/CombinableLoops
            assert_equal v, dc.get(k)
          end
        end
      end

      it 'reconciles pending quiet writes before a non-quiet mutation that reads a response' do
        with_deferred_client(p) do |dc|
          quiet_key = SecureRandom.hex(3)
          quiet_value = SecureRandom.hex(3)
          direct_key = SecureRandom.hex(3)
          direct_value = SecureRandom.hex(3)

          dc.quiet { dc.set(quiet_key, quiet_value) }

          # A non-quiet set reads a CAS response; it must drain the pending
          # quiet response first or the CAS read would be corrupted.
          assert op_addset_succeeds(dc.set(direct_key, direct_value))

          assert_equal quiet_value, dc.get(quiet_key)
          assert_equal direct_value, dc.get(direct_key)
        end
      end

      it 'does not corrupt the response stream when a quiet write errors' do
        with_deferred_client(p) do |dc|
          dc.set('a', 'av')
          dc.set('b', 'bv')

          dc.quiet do
            # Deleting a non-existent key produces an error reply that the q
            # flag does not suppress; it must be drained before later reads.
            assert_nil dc.delete('non_existent_key')
          end

          assert_equal 'av', dc.get('a')
          assert_equal 'bv', dc.get('b')
        end
      end

      it 'supports quiet deletes with deferred flushing' do
        with_deferred_client(p) do |dc|
          existing = SecureRandom.hex(4)
          missing = SecureRandom.hex(4)
          dc.set(existing, 'present')

          dc.quiet do
            assert_nil dc.delete(existing)
            assert_nil dc.delete(missing)
          end

          assert_nil dc.get(existing)
          assert_nil dc.get(missing)
        end
      end

      it 'drains pending responses explicitly via drain_deferred_responses' do
        with_deferred_client(p) do |dc|
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)

          dc.quiet { dc.set(key, value) }

          # Force reconciliation at an explicit boundary; subsequent reads then
          # require no implicit drain but still return the written value.
          dc.drain_deferred_responses

          assert_equal value, dc.get(key)
        end
      end

      it 'clears the pending flag so the next read requires no implicit drain' do
        with_deferred_client(p) do |dc|
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)

          dc.quiet { dc.set(key, value) }

          # After a deferred quiet write the server that handled the write has a
          # pending response flag set; a subsequent read would drain it before
          # proceeding.  (With multiple servers the write is routed to one of
          # them, so any? is used rather than a specific index.)
          servers = dc.send(:ring).servers

          assert servers.any?(&:quiet_responses_pending?),
                 'expected a pending response after a deferred quiet write'

          # Draining at an explicit boundary (e.g. the end of a Rack request or
          # Sidekiq job) clears the flag on all servers; the next read will not
          # need to issue an extra noop round-trip to reconcile the connection.
          dc.drain_deferred_responses

          refute servers.any?(&:quiet_responses_pending?),
                 'expected no pending responses after drain_deferred_responses'

          assert_equal value, dc.get(key)
        end
      end

      it 'is a no-op to drain_deferred_responses when nothing is pending' do
        with_deferred_client(p) do |dc|
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)
          dc.set(key, value)

          # No deferred responses outstanding -> safe no-op
          dc.drain_deferred_responses

          assert_equal value, dc.get(key)
        end
      end

      it 'still drains at the end of the block when defer_drain is off' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          noop_counts = count_noop_barriers(dc)

          dc.quiet { dc.set(SecureRandom.hex(3), 'v') }

          assert_equal 1, noop_counts.values.sum
          refute(dc.send(:ring).servers.any?(&:quiet_responses_pending?))
        end
      end

      it 'drains only the server a later request goes to' do
        memcached_persistent(p, 21_345) do |_, port1|
          memcached_persistent(p, 21_346) do |_, port2|
            dc = Dalli::Client.new(["localhost:#{port1}", "localhost:#{port2}"], defer_drain: true)
            dc.flush
            first, second = dc.send(:ring).servers
            written = key_on(dc, first, 'w')
            read = key_on(dc, second, 'r')
            dc.set(read, 'rv')

            dc.quiet { dc.set(written, 'wv') }

            assert_predicate first, :quiet_responses_pending?
            # A read from the other server needs no drain
            assert_equal 'rv', dc.get(read)
            assert_predicate first, :quiet_responses_pending?

            # A read from the written server drains it first
            assert_equal 'wv', dc.get(written)
            refute_predicate first, :quiet_responses_pending?
          end
        end
      end

      it 'pipelines set_multi across servers without a per-key round-trip under defer_drain' do
        port1 = 23_456
        port2 = 23_457
        memcached(p, port1, '', { defer_drain: true }) do
          memcached(p, port2, '', { defer_drain: true }) do
            dc = Dalli::Client.new(["127.0.0.1:#{port1}", "127.0.0.1:#{port2}"], defer_drain: true)
            dc.flush

            pairs = {}
            40.times { |i| pairs["mk#{i}"] = "mv#{i}" }

            noop_counts = count_noop_barriers(dc)
            dc.set_multi(pairs)

            total_noops = noop_counts.values.sum
            server_count = dc.send(:ring).servers.size

            # A correctly pipelined set_multi issues at most one terminating noop
            # per server.  The regression collapses it into one noop per key
            # (~40), so anything bounded by the server count proves the fix.
            assert_operator total_noops, :<=, server_count,
                            "set_multi issued #{total_noops} noop barriers across " \
                            "#{server_count} servers; expected pipelined batching"

            pairs.each { |k, v| assert_equal v, dc.get(k) }
          end
        end
      end
    end
  end
end
