# frozen_string_literal: true

require_relative '../helper'

# Integration tests for the opaque routing-token passthrough (`p_token` /
# `l_token`) on single-key commands. These are encoded as the meta protocol's
# `P<token>` / `L<token>` flags. Vanilla memcached assigns no meaning to them
# and silently ignores them (parsed as no-ops alongside the O/opaque flag);
# they exist as a passthrough hook for a proxy or router sitting in front of
# memcached. See protocol.txt.
#
# Multi-key/pipelined commands (get_multi, get_multi_cas, set_multi) and the
# delete family are covered separately -- the delete family depends on the
# tombstone options landing first, to avoid two open PRs racing to add a
# keyword argument to the same method signature.
P_TOKEN = 'pod1'
L_TOKEN = 'zone2'
ROUTING_OPTS = { p_token: P_TOKEN, l_token: L_TOKEN }.freeze

describe 'routing tokens (p_token / l_token) passthrough' do
  describe 'get / gat / get_cas / get_with_metadata' do
    it 'returns a scalar value (not a tuple) when routing tokens are passed' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        result = dc.get('rtk', ROUTING_OPTS)

        refute_kind_of Array, result
        assert_equal 'val', result

        assert_equal 'val', dc.get('rtk', p_token: P_TOKEN)
        assert_equal 'val', dc.get('rtk', l_token: L_TOKEN)
      end
    end

    it 'returns nil on a miss with routing tokens' do
      memcached_persistent do |dc|
        dc.flush

        assert_nil dc.get('absent', ROUTING_OPTS)
      end
    end

    it 'gat returns a scalar with routing tokens' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        assert_equal 'val', dc.gat('rtk', 60, ROUTING_OPTS)
      end
    end

    it 'get_cas returns the usual [value, cas] tuple with routing tokens' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        value, cas = dc.get_cas('rtk', ROUTING_OPTS)

        assert_equal 'val', value
        assert_operator cas, :positive?
      end
    end

    it 'get_with_metadata accepts routing tokens alongside its own options' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        result = dc.get_with_metadata('rtk', return_hit_status: true, **ROUTING_OPTS)

        assert_equal 'val', result[:value]
        refute result[:miss]
      end
    end
  end

  describe 'set / add / replace / set_cas / replace_cas' do
    it 'accepts routing tokens without changing return shape' do
      memcached_persistent do |dc|
        dc.flush

        result = dc.set('rtk', 'val1', nil, ROUTING_OPTS)

        assert op_addset_succeeds(result)
        refute_kind_of Array, result
        assert_equal 'val1', dc.get('rtk')

        assert op_addset_succeeds(dc.replace('rtk', 'val2', nil, ROUTING_OPTS))
        assert_equal 'val2', dc.get('rtk')

        refute dc.add('rtk', 'val3', nil, ROUTING_OPTS)

        dc.delete('rtk')

        assert op_addset_succeeds(dc.add('rtk', 'val4', nil, ROUTING_OPTS))
        assert_equal 'val4', dc.get('rtk')
      end
    end

    it 'set_cas and replace_cas accept routing tokens' do
      memcached_persistent do |dc|
        dc.flush
        cas = dc.set('rtk', 'val')

        new_cas = dc.set_cas('rtk', 'val2', cas, nil, ROUTING_OPTS)

        assert new_cas
        assert_equal 'val2', dc.get('rtk')

        assert dc.replace_cas('rtk', 'val3', new_cas, nil, ROUTING_OPTS)
        assert_equal 'val3', dc.get('rtk')
      end
    end
  end

  describe 'append / prepend' do
    it 'accepts routing tokens without changing return shape (raw mode)' do
      memcached_persistent do |dc|
        raw = single_server_client(dc.send(:ring).servers.first.port, raw: true)
        raw.flush
        raw.set('rtk', 'middle')

        assert raw.append('rtk', '-end', ROUTING_OPTS)
        assert raw.prepend('rtk', 'start-', ROUTING_OPTS)
        assert_equal 'start-middle-end', raw.get('rtk')
      end
    end
  end

  describe 'incr / decr' do
    it 'accepts routing tokens and adjusts the counter, return shape unchanged' do
      memcached_persistent do |dc|
        dc.flush

        v = dc.incr('counter', 1, 60, 5, ROUTING_OPTS)

        assert_kind_of Integer, v
        assert_equal 5, v
        assert_equal 6, dc.incr('counter', 1, 60, 5, ROUTING_OPTS)
        assert_equal 4, dc.decr('counter', 2, 60, 5, ROUTING_OPTS)
      end
    end
  end

  describe 'cas / cas! / fetch_with_lock' do
    it 'cas accepts routing tokens' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        new_cas = dc.cas('rtk', nil, ROUTING_OPTS) { |v| "#{v}!" }

        assert new_cas
        assert_equal 'val!', dc.get('rtk')
      end
    end

    it 'fetch_with_lock threads routing tokens into every request it issues' do
      memcached_persistent do |dc|
        dc.flush

        result = dc.fetch_with_lock('rtk', ttl: 100, lock_ttl: 30, req_options: ROUTING_OPTS) { 'regenerated' }

        assert_equal 'regenerated', result
        assert_equal 'regenerated', dc.get('rtk')
      end
    end
  end

  describe 'wire-format hardening' do
    # p_token and l_token are appended verbatim to every meta-protocol request
    # line. Without sanitization, a value like "foo\r\nflush_all\r\n" would be
    # parsed as a second command by memcached or any intermediate proxy/LB.
    it 'rejects a p_token containing CRLF with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.set('safe_key', 'val', nil, p_token: "route=us\r\ninjected")
        end
      end
    end

    it 'rejects an l_token containing a null byte with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.get('safe_key', l_token: "hint\0null")
        end
      end
    end

    it 'rejects non-String tokens with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.set('safe_key', 'val', nil, p_token: 12_345)
        end
      end
    end

    it 'treats empty-string tokens as no-ops' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        assert_equal 'val', dc.get('rtk', p_token: '', l_token: '')
        assert op_addset_succeeds(dc.set('rtk2', 'v', nil, p_token: ''))
      end
    end

    # An empty non-String must still be rejected as "not a String" -- only an
    # empty String is a no-op. The client-side check duplicates the
    # formatter's; if the client-side copy alone regressed to treating any
    # empty object as a no-op, the formatter would still raise, but only
    # after the request reached Protocol::Base#request -- reintroducing the
    # connection-closing failure mode this layer exists to avoid. Asserting
    # on connected? isolates that the client-side copy is independently
    # correct, not merely backstopped by the formatter.
    it 'does not treat an empty non-String token as a no-op, and does not close the connection' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush
        dc.set('rtk', 'val')
        conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

        assert_raises(ArgumentError) { dc.get('rtk', p_token: []) }
        assert_predicate conn_mgr, :connected?, 'an empty Array p_token closed the connection'

        assert_raises(ArgumentError) { dc.get('rtk', l_token: {}) }
        assert_predicate conn_mgr, :connected?, 'an empty Hash l_token closed the connection'
      end
    end

    # A bad token must be rejected before any bytes reach the socket: the
    # request never enters Protocol::Base#request, so there is nothing to
    # tear down. Checking the connection directly matters here -- a version
    # that instead raised from deep inside the request (formatter-level only)
    # would ALSO pass a "does a subsequent call still work" check, because
    # Dalli transparently reconnects. That would hide the exact bug this
    # guards against, so this asserts on connection state, not just behavior.
    it 'rejects bad tokens before touching the connection, on every affected method' do
      memcached_persistent do |_dc, port|
        dc = single_server_client(port)
        dc.flush
        dc.set('rtk', 'val')
        conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

        checks = {
          get: -> { dc.get('rtk', p_token: "bad\r\n") },
          gat: -> { dc.gat('rtk', 60, p_token: "bad\r\n") },
          get_cas: -> { dc.get_cas('rtk', p_token: "bad\r\n") },
          get_with_metadata: -> { dc.get_with_metadata('rtk', p_token: "bad\r\n") },
          set: -> { dc.set('rtk', 'v', nil, p_token: "bad\r\n") },
          set_cas: -> { dc.set_cas('rtk', 'v', 1, nil, p_token: "bad\r\n") },
          add: -> { dc.add('other', 'v', nil, p_token: "bad\r\n") },
          replace: -> { dc.replace('rtk', 'v', nil, p_token: "bad\r\n") },
          replace_cas: -> { dc.replace_cas('rtk', 'v', 1, nil, p_token: "bad\r\n") },
          append: -> { dc.append('rtk', 'v', p_token: "bad\r\n") },
          prepend: -> { dc.prepend('rtk', 'v', p_token: "bad\r\n") },
          incr: -> { dc.incr('rtk', 1, nil, nil, p_token: "bad\r\n") },
          decr: -> { dc.decr('rtk', 1, nil, nil, p_token: "bad\r\n") },
          cas: -> { dc.cas('rtk', nil, { p_token: "bad\r\n" }) { |v| v } },
          fetch_with_lock: lambda {
            dc.fetch_with_lock('rtk', req_options: { p_token: "bad\r\n" }) { 'x' }
          }
        }

        checks.each do |name, blk|
          assert_raises(ArgumentError, "expected #{name} to raise") { blk.call }
          assert_predicate conn_mgr, :connected?, "#{name} closed the connection on a rejected token"
        end

        assert_equal 'val', dc.get('rtk')
      end
    end
  end

  describe 'wire verification' do
    # memcached ignores unknown-but-well-formed flags, so an operation that
    # succeeds with routing tokens attached does not by itself prove the
    # tokens were transmitted -- a formatter bug that silently dropped them
    # would pass every test above too. This proves the bytes are actually on
    # the wire, for a representative read, write, and arithmetic command.
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
              when 'mg' then c.write("EN\r\n")
              when 'ms'
                c.read(line.split[2].to_i + 2)
                c.write("HD\r\n")
              when 'ma' then c.write("HD 0\r\n")
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

    it 'puts P and L tokens on the wire for get, set, and incr' do
      port = rand(22_133..22_632)
      capture_requests(port) do |captured|
        dc = Dalli::Client.new("127.0.0.1:#{port}", socket_timeout: 2)

        begin
          dc.get('k', ROUTING_OPTS)
        rescue Dalli::DalliError
          nil
        end
        begin
          dc.set('k', 'v', nil, p_token: 'podA')
        rescue Dalli::DalliError
          nil
        end
        begin
          dc.incr('k', 1, nil, nil, l_token: 'zoneX')
        rescue Dalli::DalliError
          nil
        end

        get_line = captured.find { |l| l.start_with?('mg') }
        set_line = captured.find { |l| l.start_with?('ms') }
        incr_line = captured.find { |l| l.start_with?('ma') }

        assert_includes get_line, "P#{P_TOKEN}", "expected P#{P_TOKEN} in #{get_line.inspect}"
        assert_includes get_line, "L#{L_TOKEN}", "expected L#{L_TOKEN} in #{get_line.inspect}"
        assert_includes set_line, 'PpodA', "expected PpodA in #{set_line.inspect}"
        assert_includes incr_line, 'LzoneX', "expected LzoneX in #{incr_line.inspect}"
      end
    end

    # fetch_with_lock_request builds its own vivify_ttl/recache_ttl from its
    # own lock_ttl:/recache_threshold: parameters, then merges req_options in.
    # If req_options were the override instead of the base, a caller-supplied
    # req_options[:vivify_ttl] would silently replace lock_ttl on the wire.
    # This proves lock_ttl always wins, while p_token from req_options still
    # comes through on the same request.
    it 'lets lock_ttl win over a colliding :vivify_ttl in req_options' do
      port = rand(22_133..22_632)
      capture_requests(port) do |captured|
        dc = Dalli::Client.new("127.0.0.1:#{port}", socket_timeout: 2)

        dc.fetch_with_lock('k', lock_ttl: 30, req_options: { vivify_ttl: 99_999, p_token: 'podA' }) { 'x' }

        get_line = captured.find { |l| l.start_with?('mg') }

        assert_includes get_line, 'N30', "expected the real lock_ttl (N30) in #{get_line.inspect}"
        refute_includes get_line, 'N99999', 'req_options[:vivify_ttl] must not override lock_ttl'
        assert_includes get_line, 'PpodA', "expected PpodA in #{get_line.inspect}"
      end
    end
  end
end
