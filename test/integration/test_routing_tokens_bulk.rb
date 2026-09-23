# frozen_string_literal: true

require_relative '../helper'

# Integration tests for the opaque routing-token passthrough (`p_token` /
# `l_token`) on bulk operations (get_multi, get_multi_cas, set_multi,
# delete_multi, get_multi_with_metadata) and the delete family (delete,
# delete_cas), which #1147 deferred -- delete/delete_cas because #1145/#1146
# were already adding keyword parameters to the same methods, the rest
# because they needed their own PR. See test_routing_tokens.rb for the
# single-key half and the protocol background.
BULK_P_TOKEN = 'pod1'
BULK_L_TOKEN = 'zone2'
BULK_ROUTING_OPTS = { p_token: BULK_P_TOKEN, l_token: BULK_L_TOKEN }.freeze

describe 'routing tokens (p_token / l_token) passthrough -- bulk operations' do
  # Temporarily wraps a PipelinedGetter instance method to record the args it
  # was called with, so a test can prove req_options reached that layer
  # rather than only checking a result memcached would return unchanged
  # either way (it ignores routing tokens). Restored after the block runs.
  def capture_pipelined_getter_call(method_name)
    seen_args = nil
    original = Dalli::PipelinedGetter.instance_method(method_name)
    # remove_method first: redefining a method that already exists on this
    # exact class triggers Ruby's "method redefined" warning, which this
    # suite's -w run treats as fatal (see test_strict_warnings.rb).
    Dalli::PipelinedGetter.remove_method(method_name)
    Dalli::PipelinedGetter.define_method(method_name) do |*args, &block|
      seen_args = args
      original.bind_call(self, *args, &block)
    end

    yield

    seen_args
  ensure
    Dalli::PipelinedGetter.remove_method(method_name)
    Dalli::PipelinedGetter.define_method(method_name, original)
  end

  # memcached_persistent yields a client with a two-entry ring (the pipelined
  # path); single_server_client takes the single-server fast path. Both are
  # exercised for every method with one, since routing tokens are threaded
  # through separately on each.
  describe 'get_multi' do
    it 'accepts routing tokens on the pipelined path without changing the result' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')
        dc.set('b', 'vb')

        result = dc.get_multi(%w[a b], req_options: BULK_ROUTING_OPTS)

        assert_equal({ 'a' => 'va', 'b' => 'vb' }, result)
      end
    end

    it 'accepts routing tokens on the single-server fast path' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush
        dc.set('a', 'va')

        assert_equal({ 'a' => 'va' }, dc.get_multi(%w[a], req_options: BULK_ROUTING_OPTS))
      end
    end

    it 'accepts routing tokens in block form' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        collected = {}
        result = dc.get_multi('a', req_options: BULK_ROUTING_OPTS) { |k, v| collected[k] = v }

        assert_equal({ 'a' => 'va' }, collected)
        assert_nil result
      end
    end

    # memcached ignores routing tokens, so a passing result above doesn't
    # prove req_options actually reached the pipelined dispatch -- a plumbing
    # bug that silently dropped it between PipelinedGetter and Base#request
    # would pass those tests too. Records what actually crosses the
    # server.request wire boundary, on whichever ring server key 'a' hashes
    # to (both are wrapped, since which one that is isn't worth pinning down).
    it 'threads req_options into the :pipelined_get dispatch' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')
        seen_args = nil

        dc.send(:ring).servers.each do |server|
          original = server.method(:request)
          server.define_singleton_method(:request) do |opkey, *args|
            seen_args = args if opkey == :pipelined_get
            original.call(opkey, *args)
          end
        end

        dc.get_multi(%w[a], req_options: BULK_ROUTING_OPTS)

        # The third argument is return_cas, false for plain get_multi
        assert_equal [%w[a], BULK_ROUTING_OPTS], seen_args.first(2)
      end
    end
  end

  describe 'get_multi_cas' do
    it 'accepts routing tokens without changing the result shape' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        result = dc.get_multi_cas(%w[a], req_options: BULK_ROUTING_OPTS)

        assert_equal 'va', result['a'].first
        assert_operator result['a'].last, :positive?
      end
    end

    it 'threads req_options into PipelinedGetter#process' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        seen_args = capture_pipelined_getter_call(:process) do
          dc.get_multi_cas(%w[a], req_options: BULK_ROUTING_OPTS)
        end

        # get_multi_cas, unlike get_multi, does not flatten its *keys splat --
        # a pre-existing quirk this test isn't asserting on, just matching.
        assert_equal [[%w[a]], BULK_ROUTING_OPTS], seen_args
      end
    end
  end

  describe 'get_multi_with_metadata' do
    it 'accepts routing tokens on the pipelined path' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        result = dc.get_multi_with_metadata('a', req_options: BULK_ROUTING_OPTS)

        assert_equal 'va', result['a'][:value]
      end
    end

    it 'accepts routing tokens on the single-server fast path' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush
        dc.set('a', 'va')

        result = dc.get_multi_with_metadata('a', req_options: BULK_ROUTING_OPTS)

        assert_equal 'va', result['a'][:value]
      end
    end

    it 'threads req_options into PipelinedGetter#process_with_metadata' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        seen_args = capture_pipelined_getter_call(:process_with_metadata) do
          dc.get_multi_with_metadata('a', req_options: BULK_ROUTING_OPTS)
        end

        assert_equal [['a'], BULK_ROUTING_OPTS], seen_args
      end
    end
  end

  describe 'set_multi' do
    it 'accepts routing tokens on the pipelined path' do
      memcached_persistent do |dc|
        dc.flush

        dc.set_multi({ 'a' => 'va', 'b' => 'vb' }, nil, BULK_ROUTING_OPTS)

        assert_equal 'va', dc.get('a')
        assert_equal 'vb', dc.get('b')
      end
    end

    it 'accepts routing tokens on the single-server fast path' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush

        dc.set_multi({ 'a' => 'va' }, nil, BULK_ROUTING_OPTS)

        assert_equal 'va', dc.get('a')
      end
    end
  end

  describe 'delete / delete_cas' do
    it 'accepts routing tokens without changing the return value' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        assert dc.delete('a', BULK_ROUTING_OPTS)
        assert_nil dc.get('a')
      end
    end

    it 'delete_cas accepts routing tokens alongside a CAS check' do
      memcached_persistent do |dc|
        dc.flush
        cas = dc.set('a', 'va')

        assert dc.delete_cas('a', cas, BULK_ROUTING_OPTS)
      end
    end
  end

  describe 'delete_multi' do
    it 'accepts routing tokens on the pipelined path' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')
        dc.set('b', 'vb')

        assert_equal 2, dc.delete_multi(%w[a b], BULK_ROUTING_OPTS)
        assert_nil dc.get('a')
        assert_nil dc.get('b')
      end
    end

    it 'accepts routing tokens on the single-server fast path' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush
        dc.set('a', 'va')

        assert_equal 1, dc.delete_multi(%w[a], BULK_ROUTING_OPTS)
      end
    end

    it 'combines routing tokens with tombstone options' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', 'va')

        dc.delete_multi(%w[a], invalidate: true, **BULK_ROUTING_OPTS)

        result = dc.get_multi_with_metadata('a')

        assert result['a'][:stale]
      end
    end
  end

  describe 'wire-format hardening' do
    # Same failure mode #1147 guarded against for single-key methods: reaching
    # only the formatter's check means unwinding through Protocol::Base#request,
    # which closes the connection. Client-side validation must reject the bad
    # token before any bytes go out, on every bulk entry point.
    it 'rejects bad tokens before touching the connection, on every affected method' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush
        dc.set('a', 'va')
        conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

        checks = {
          get_multi: -> { dc.get_multi('a', req_options: { p_token: "bad\r\n" }) },
          get_multi_cas: -> { dc.get_multi_cas('a', req_options: { p_token: "bad\r\n" }) },
          get_multi_with_metadata: -> { dc.get_multi_with_metadata('a', req_options: { p_token: "bad\r\n" }) },
          set_multi: -> { dc.set_multi({ 'a' => 'v' }, nil, { p_token: "bad\r\n" }) },
          delete: -> { dc.delete('a', p_token: "bad\r\n") },
          delete_cas: -> { dc.delete_cas('a', 0, p_token: "bad\r\n") },
          delete_multi: -> { dc.delete_multi(%w[a], p_token: "bad\r\n") }
        }

        checks.each do |name, blk|
          assert_raises(ArgumentError, "expected #{name} to raise") { blk.call }
          assert_predicate conn_mgr, :connected?, "#{name} closed the connection on a rejected token"
        end

        assert_equal 'va', dc.get('a')
      end
    end
  end

  describe 'wire verification' do
    # quiet_get_request builds the per-key request line the pipelined
    # multi-server path (Base#pipelined_get/#pipelined_get_interleaved) sends
    # for get_multi/get_multi_cas/get_multi_with_metadata. It has no
    # single-server-fast-path equivalent to cross-check it against, so it is
    # checked directly here rather than relying only on a live wire capture,
    # which would need a second real memcached to exercise a genuine
    # multi-server ring.
    it 'quiet_get_request includes routing tokens' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        server = dc.send(:ring).servers.first

        req = server.send(:quiet_get_request, 'k', BULK_ROUTING_OPTS)

        assert_includes req, "P#{BULK_P_TOKEN}"
        assert_includes req, "L#{BULK_L_TOKEN}"
      end
    end

    # memcached ignores unknown-but-well-formed flags, so a bulk operation
    # succeeding with routing tokens attached does not by itself prove the
    # tokens were transmitted on every line of the batch. This proves the
    # bytes are actually on the wire for a representative multi-get,
    # multi-set, and multi-delete, applied to every key in the batch.
    def capture_requests(port)
      server = TCPServer.new('127.0.0.1', port)
      captured = []
      thread = Thread.new do
        loop do
          conn = server.accept
          Thread.new(conn) do |c|
            while (line = c.gets("\r\n"))
              captured << line.chomp
              case line.split.first
              when 'version' then c.write("VERSION 1.6.45-fake\r\n")
              when 'mg' then c.write("EN\r\n") # skipped by the client (not VA), harmless
              when 'ms'
                c.read(line.split[2].to_i + 2) # drain the value bytes; quiet suppresses the response
              when 'md' then nil # quiet; response only comes via the terminating mn
              when 'mn' then c.write("MN\r\n")
              else c.write("ERROR\r\n")
              end
            end
          rescue IOError, Errno::ECONNRESET
            nil
          end
        rescue IOError
          nil
        end
      end
      thread.abort_on_exception = true

      yield captured
    ensure
      server&.close
      thread&.kill
    end

    it 'puts P and L tokens on every line of a multi-get, multi-set, and multi-delete' do
      port = rand(22_633..23_132)
      capture_requests(port) do |captured|
        dc = Dalli::Client.new("127.0.0.1:#{port}", socket_timeout: 2)

        begin
          dc.get_multi(%w[a b], req_options: BULK_ROUTING_OPTS)
        rescue Dalli::DalliError
          nil
        end
        begin
          dc.set_multi({ 'a' => 'va', 'b' => 'vb' }, nil, BULK_ROUTING_OPTS)
        rescue Dalli::DalliError
          nil
        end
        begin
          dc.delete_multi(%w[a b], BULK_ROUTING_OPTS)
        rescue Dalli::DalliError
          nil
        end

        get_lines = captured.select { |l| l.start_with?('mg') }
        set_lines = captured.select { |l| l.start_with?('ms') }
        delete_lines = captured.select { |l| l.start_with?('md') }

        assert_equal 2, get_lines.size
        assert_equal 2, set_lines.size
        assert_equal 2, delete_lines.size

        (get_lines + set_lines + delete_lines).each do |line|
          assert_includes line, "P#{BULK_P_TOKEN}", "expected P#{BULK_P_TOKEN} in #{line.inspect}"
          assert_includes line, "L#{BULK_L_TOKEN}", "expected L#{BULK_L_TOKEN} in #{line.inspect}"
        end
      end
    end
  end
end
