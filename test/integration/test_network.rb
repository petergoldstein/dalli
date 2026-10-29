# frozen_string_literal: true

require_relative '../helper'

# Forwards connections to a real memcached, except that the reply to the
# first request matching `lose` never arrives: the proxy forwards the request,
# waits for memcached's reply (so the request has been applied), discards it,
# holds the connection open for `delay` seconds and then closes it. Requests
# on later connections are forwarded as is. With drop_first_connection, the
# first connection is closed as soon as it is accepted, before Dalli has
# written anything to it.
class ReplyLosingProxy
  attr_reader :port

  def initialize(upstream_port, lose: ->(_line) { false }, delay: 0, drop_first_connection: false)
    @upstream_port = upstream_port
    @lose = lose
    @delay = delay
    @drop_first_connection = drop_first_connection
    @mutex = Mutex.new
    @commands = []
    @lost = false
    @sockets = []
    @threads = []
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @acceptor = Thread.new { accept_connections }
  end

  # How many requests with this command (such as 'ma') the proxy forwarded
  def count(command)
    @mutex.synchronize { @commands.count(command) }
  end

  def close
    @server.close
    @acceptor.kill
    @mutex.synchronize do
      @threads.each(&:kill)
      @sockets.each(&:close)
    end
  end

  private

  def accept_connections
    drop = @drop_first_connection
    loop do
      client = @server.accept
      if drop
        drop = false
        client.close
        next
      end
      @mutex.synchronize { @threads << Thread.new { forward(client) } }
    end
  rescue IOError, SystemCallError
    nil
  end

  def forward(client)
    upstream = TCPSocket.new('127.0.0.1', @upstream_port)
    @mutex.synchronize { @sockets.push(client, upstream) }
    muted = Queue.new
    replied = Queue.new
    pump = Thread.new { pump_replies(upstream, client, muted, replied) }
    forward_requests(client, upstream, muted, replied)
  rescue IOError, SystemCallError
    nil
  ensure
    pump&.kill
    client.close
    upstream&.close
  end

  def forward_requests(client, upstream, muted, replied)
    while (line = client.gets("\r\n"))
      command, _key, size = line.split
      data = client.read(size.to_i + 2) if command == 'ms'
      lose = record(command, line)
      muted << true if lose
      upstream.write(line)
      upstream.write(data) if data
      next unless lose

      replied.pop(timeout: 5)
      sleep @delay
      return
    end
  end

  def pump_replies(upstream, client, muted, replied)
    loop do
      data = upstream.readpartial(65_536)
      if muted.empty?
        client.write(data)
      else
        replied << true
      end
    end
  rescue IOError, SystemCallError
    nil
  end

  # Returns true for the request whose reply is to be lost
  def record(command, line)
    @mutex.synchronize do
      @commands << command
      next false if @lost || !@lose.call(line)

      @lost = true
    end
  end
end

describe 'Network' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'assuming a bad network' do
        it 'handle no server available' do
          dc = Dalli::Client.new 'localhost:19333'
          assert_error Dalli::RingError, /No server available/ do
            dc.get 'foo'
          end
        end

        # Only where socket reads time out (CRuby with IO#timeout=). On JRuby,
        # TruffleRuby or Ruby 3.1, a silent server blocks the read itself
        # rather than exercising the retries.
        if RUBY_ENGINE == 'ruby' && IO.method_defined?(:timeout=)
          # Each retry used to reconnect successfully, which reset the failure
          # count, so a server that accepts connections but never answers was
          # retried forever and the caller hung.
          it 'gives up on a server that accepts connections but never answers' do
            server = TCPServer.new('127.0.0.1', 19_456)
            acceptor = Thread.new do
              loop do
                Thread.new(server.accept) do |sock|
                  while (line = sock.gets)
                    sock.write("VERSION 1.6.45\r\n") if line.start_with?('version')
                  end
                rescue IOError, SystemCallError
                  nil
                end
              end
            rescue IOError
              nil
            end
            dc = Dalli::Client.new('127.0.0.1:19456', socket_timeout: 0.3, protocol: p)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            assert_raises(Dalli::NetworkError) { dc.get('anykey') }
            assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
          ensure
            server&.close
            acceptor&.kill
          end

          # get_with_metadata requires the meta protocol
          if p == :meta
            # get_with_metadata and fetch_with_lock also retried the final
            # NetworkError raised when the server is marked down, so with
            # down_retry_delay: 0 they retried the same server forever.
            it 'gives up in get_with_metadata and fetch_with_lock with down_retry_delay: 0' do
              server = TCPServer.new('127.0.0.1', 19_457)
              acceptor = Thread.new do
                loop do
                  Thread.new(server.accept) do |sock|
                    while (line = sock.gets)
                      sock.write("VERSION 1.6.45\r\n") if line.start_with?('version')
                    end
                  rescue IOError, SystemCallError
                    nil
                  end
                end
              rescue IOError
                nil
              end
              dc = Dalli::Client.new('127.0.0.1:19457', socket_timeout: 0.2, down_retry_delay: 0, protocol: p)

              [-> { dc.get_with_metadata('k') }, -> { dc.fetch_with_lock('k') { 'v' } }].each do |call|
                started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

                assert_raises(Dalli::NetworkError, Dalli::RingError) { call.call }
                assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
              end
            ensure
              server&.close
              acceptor&.kill
            end
          end
        end

        # A get_multi that runs out of time overall isn't a socket failure, so
        # slow ones in a row must not mark the server down.
        it 'keeps a server that answers get_multi slowly' do
          server = TCPServer.new('127.0.0.1', 19_459)
          acceptor = Thread.new do
            loop do
              Thread.new(server.accept) do |sock|
                pending = []
                while (line = sock.gets)
                  words = line.split
                  case words.first
                  when 'version' then sock.write("VERSION 1.6.45\r\n")
                  when 'mg' then pending << words[1]
                  when 'ms'
                    sock.read(words[2].to_i + 2)
                    sock.write("HD\r\n")
                  when 'mn'
                    first, *rest = pending
                    sock.write("VA 1 f0 k#{first} s1\r\nv\r\n")
                    sleep 0.5 # longer than the client's socket_timeout
                    rest.each { |k| sock.write("VA 1 f0 k#{k} s1\r\nv\r\n") }
                    sock.write("MN\r\n")
                    pending.clear
                  end
                end
              rescue IOError, SystemCallError
                nil
              end
            end
          rescue IOError
            nil
          end
          dc = Dalli::Client.new('127.0.0.1:19459', socket_timeout: 0.3, protocol: p)

          with_nil_logger do
            3.times do
              yielded = []
              dc.get_multi('a', 'b', 'c') { |k, _| yielded << k }

              assert_equal ['a'], yielded
            end
          end

          assert dc.set('after', 'ok')
        ensure
          server&.close
          acceptor&.kill
        end

        describe 'with a fake server' do
          it 'handle connection reset' do
            memcached_mock(lambda(&:close)) do
              dc = Dalli::Client.new('localhost:19123')
              assert_error Dalli::RingError, /No server available/ do
                dc.get('abc')
              end
            end
          end

          it 'handle connection reset with unix socket' do
            socket_path = MemcachedMock::UNIX_SOCKET_PATH
            memcached_mock(lambda(&:close), :start_unix, socket_path) do
              dc = Dalli::Client.new(socket_path)
              assert_error Dalli::RingError, /No server available/ do
                dc.get('abc')
              end
            end
          end

          it 'handle malformed response' do
            memcached_mock(->(sock) { sock.write('123') }) do
              dc = Dalli::Client.new('localhost:19123')
              assert_error Dalli::RingError, /No server available/ do
                dc.get('abc')
              end
            end
          end

          it 'handle socket timeouts' do
            dc = Dalli::Client.new('localhost:19123', socket_timeout: 0)
            assert_raises Dalli::RingError do
              dc.get('abc')
            end
          end

          it 'handle connect timeouts' do
            memcached_mock(lambda { |sock|
                             sleep(0.6)
                             sock.close
                           }, :delayed_start) do
              dc = Dalli::Client.new('localhost:19123')
              assert_error Dalli::RingError, /No server available/ do
                dc.get('abc')
              end
            end
          end

          it 'handle read timeouts' do
            memcached_mock(lambda { |sock|
                             sleep(0.6)
                             sock.write('giraffe')
                           }) do
              dc = Dalli::Client.new('localhost:19123')
              assert_error Dalli::RingError, /No server available/ do
                dc.get('abc')
              end
            end
          end
        end

        it 'closes the connection when a reply line has no CRLF within the line limit' do
          memcached_mock(lambda { |sock|
            while (line = sock.gets)
              if line.start_with?('version')
                sock.write("VERSION 1.6.45\r\n")
              else
                sock.write('x' * (64 * 1024)) # never ends the line
              end
            end
          }, :start, [19_141]) do
            dc = Dalli::Client.new('localhost:19141', socket_timeout: 5, socket_max_failures: 0,
                                                      socket_failure_delay: 0.0, down_retry_delay: 0.0)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            assert_raises Dalli::NetworkError do
              dc.get('abc')
            end

            # Raised as soon as the limit is hit, not after the socket timeout
            assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
            refute_predicate dc.send(:ring).servers.first, :connected?
          end
        end

        it 'handles operation timeouts' do
          memcached_mock(lambda { |sock|
            # handle initial version call
            sock.gets
            sock.write("VERSION 1.6.0\r\n")

            sleep(0.3)
          }) do
            dc = Dalli::Client.new('localhost:19123', socket_timeout: 0.1, protocol: p, socket_max_failures: 0,
                                                      socket_failure_delay: 0.0, down_retry_delay: 0.0)
            # With socket_max_failures: 0, the first error triggers down! which raises NetworkError.
            # This NetworkError is not retried (only RetryableNetworkError is).
            assert_raises Dalli::NetworkError do
              dc.get('abc')
            end
          end
        end

        it 'does not retry NetworkError from down! with socket_max_failures: 0' do
          next if p == :binary

          memcached_mock(lambda { |sock|
            # handle initial version call
            sock.gets
            sock.write("VERSION 1.6.0\r\n")

            # handle the get request but never respond, causing timeout
            sock.gets
            sleep(0.3)
          }) do
            dc = Dalli::Client.new('localhost:19123', socket_timeout: 0.1, protocol: p, socket_max_failures: 0,
                                                      socket_failure_delay: 0.0, down_retry_delay: 0.0)
            # With socket_max_failures: 0, the first error triggers down! which raises NetworkError.
            # This NetworkError should NOT be caught and retried by perform (only RetryableNetworkError is).
            err = assert_raises Dalli::NetworkError do
              dc.get('abc')
            end
            assert_match(/is down/, err.message)
          end
        end

        it 'opens a standard TCP connection when ssl_context is not configured' do
          memcached_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            sock = Dalli::Socket::TCP.open(server.hostname, server.port, server.options)

            assert_instance_of Dalli::Socket::TCP, sock

            dc.set('abc', 123)

            assert_equal(123, dc.get('abc'))
          end
        end

        it 'opens a SSL TCP connection when there is an SSL context set' do
          memcached_ssl_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            sock = Dalli::Socket::TCP.open(server.hostname, server.port, server.options)

            assert_instance_of Dalli::Socket::SSLSocket, sock

            dc.set('abc', 123)

            assert_equal(123, dc.get('abc'))

            # Confirm that pipelined get works, since this depends on attributes on
            # the socket
            assert_equal({ 'abc' => 123 }, dc.get_multi(['abc']))
          end
        end

        it 'reads large pipelined replies over SSL' do
          memcached_ssl_persistent(p) do |dc|
            # 150KB of replies spans many TLS records, so read_available sees
            # both short and full-chunk reads on the pipelined path
            values = Array.new(50) { |i| ["big#{i}", ('a'..'z').to_a.sample * 3_000] }.to_h
            values.each { |k, v| dc.set(k, v) }

            yielded = {}
            dc.get_multi(values.keys) { |k, v| yielded[k] = v } # the block form uses the pipelined path

            assert_equal values, yielded
          end
        end

        it 'allow TCP connections to be configured for keepalive' do
          memcached_persistent(p) do |_, port|
            dc = Dalli::Client.new("localhost:#{port}", keepalive: true)
            dc.set(:a, 1)
            ring = dc.send(:ring)
            server = ring.servers.first
            socket = server.sock

            optval = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE)
            optval = optval.unpack 'i'

            refute_equal(optval[0], 0)
          end
        end

        it 'fails when SSL client connects to non-SSL server' do
          memcached_persistent(p) do |_, port|
            ssl_context = OpenSSL::SSL::SSLContext.new
            ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE

            dc = Dalli::Client.new("localhost:#{port}", ssl_context: ssl_context, protocol: p)

            # The SSL handshake fails against a non-SSL server, which marks
            # the only server down
            with_nil_logger do
              assert_error(Dalli::RingError, /No server available/) { dc.get('abc') }
            end
          end
        end

        it 'fails when SSL verification fails due to untrusted certificate' do
          memcached_ssl_persistent(p) do |_, port|
            # Create SSL context that does not trust the test CA
            strict_ssl_context = OpenSSL::SSL::SSLContext.new
            strict_ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
            # Don't set ca_file, so the self-signed cert won't be trusted

            dc = Dalli::Client.new("localhost:#{port}", ssl_context: strict_ssl_context, protocol: p)

            # SSL verification fails due to untrusted certificate
            with_nil_logger do
              assert_error(Dalli::RingError, /No server available/) { dc.get('abc') }
            end
          end
        end

        describe 'when the TLS handshake fails' do
          # A plain TCP server that answers with a non-TLS reply and hangs up
          def with_garbage_server
            server = TCPServer.new('127.0.0.1', 0)
            acceptor = Thread.new do
              loop do
                sock = server.accept
                sock.write("ERROR not a TLS server\r\n")
                sock.close
              end
            rescue IOError, SystemCallError
              nil
            end
            yield server.addr[1]
          ensure
            server&.close
            acceptor&.kill
            acceptor&.join
          end

          it 'raises a Dalli::NetworkError rather than an OpenSSL error' do
            with_garbage_server do |port|
              manager = Dalli::Protocol::ConnectionManager.new(
                '127.0.0.1', port, :tcp,
                ssl_context: CertificateGenerator.ssl_context, socket_failure_delay: nil
              )

              with_nil_logger do
                assert_raises(Dalli::RetryableNetworkError) { manager.establish_connection }
              end
            end
          end

          it 'marks the server down after socket_max_failures' do
            with_garbage_server do |port|
              manager = Dalli::Protocol::ConnectionManager.new(
                '127.0.0.1', port, :tcp,
                ssl_context: CertificateGenerator.ssl_context, socket_max_failures: 2, socket_failure_delay: nil
              )

              with_nil_logger do
                assert_raises(Dalli::RetryableNetworkError) { manager.establish_connection }
                err = assert_raises(Dalli::NetworkError) { manager.establish_connection }

                refute_kind_of Dalli::RetryableNetworkError, err
                assert_match(/is down.*OpenSSL::SSL::SSLError/, err.message)
                refute_predicate manager, :reconnect_down_server?
              end
            end
          end

          it 'fails over to another server' do
            with_garbage_server do |bad_port|
              memcached_ssl_persistent(p) do |_, good_port|
                dc = Dalli::Client.new(["127.0.0.1:#{bad_port}", "127.0.0.1:#{good_port}"],
                                       ssl_context: CertificateGenerator.ssl_context, protocol: p,
                                       socket_failure_delay: nil)

                with_nil_logger do
                  20.times { |i| dc.set("failover#{i}", i) }

                  assert_equal(19, dc.get('failover19'))
                end
              end
            end
          end
        end
      end

      it 'handles timeout error during pipelined get' do
        with_nil_logger do
          memcached(p, 19_191) do |dc|
            dc.send(:ring).server_for_key('abc').sock.stub(:write, proc { raise Timeout::Error }) do
              assert_empty dc.get_multi(['abc'])
            end
          end
        end
      end

      it 'handles SSL error during read operations' do
        # JRuby's socket classes don't support Minitest's stub method aliasing
        skip 'Minitest stub incompatible with JRuby sockets' if RUBY_ENGINE == 'jruby'

        with_nil_logger do
          memcached(p, 19_191) do |dc|
            # First set a value so we have something to get
            dc.set('ssl_test_key', 'test_value')

            server = dc.send(:ring).server_for_key('ssl_test_key')

            # Stub error_on_request! to verify SSLError triggers error handling
            # This confirms the SSL error is caught by the rescue clause
            error_handled = false
            original_error_on_request = server.instance_variable_get(:@connection_manager).method(:error_on_request!)

            server.instance_variable_get(:@connection_manager).define_singleton_method(:error_on_request!) do |err|
              error_handled = true if err.is_a?(OpenSSL::SSL::SSLError)
              original_error_on_request.call(err)
            end

            ssl_error = OpenSSL::SSL::SSLError.new('SSL_read: unexpected eof while reading')

            server.sock.stub(:gets, proc { raise ssl_error }) do
              # The operation will retry with a new connection and may succeed
              # What matters is the SSLError is caught, not propagated
              dc.get('ssl_test_key')
            rescue Dalli::NetworkError
              # Expected if retries exhausted
            end

            assert error_handled, 'SSLError should trigger error_on_request!'
          end
        end
      end

      it 'handles SSL error during pipelined get' do
        with_nil_logger do
          memcached(p, 19_191) do |dc|
            ssl_error = OpenSSL::SSL::SSLError.new('SSL_read: unexpected eof while reading')

            dc.send(:ring).server_for_key('abc').sock.stub(:write, proc { raise ssl_error }) do
              assert_empty dc.get_multi(['abc'])
            end
          end
        end
      end

      it 'handles closed socket with IOError' do
        with_nil_logger do
          memcached_persistent(p) do |dc|
            dc.set('test_key', 'test_value')

            # Force close the socket to simulate IOError: closed stream
            server = dc.instance_variable_get(:@ring).servers.first
            socket = server.instance_variable_get(:@connection_manager).sock
            socket&.close

            # Should recover by reconnecting and return the cached value
            assert_equal 'test_value', dc.get('test_key')
          end
        end
      end

      it 'handles asynchronous Thread#raise' do
        with_nil_logger do
          memcached(p, 19_191) do |dc|
            10.times do |i|
              # Pre-set the key so we're testing Thread#raise handling,
              # not whether the set completed before interruption
              dc.set("key:#{i}", i.to_s)

              thread = Thread.new do
                loop do
                  assert_instance_of Integer, dc.set("key:#{i}", i.to_s)
                end
              rescue RuntimeError
                nil # expected
              end
              thread.join(rand(0.01..0.2))

              thread.raise('Test Timeout Error')
              joined_thread = thread.join(1)

              refute_nil joined_thread
              refute_predicate joined_thread, :alive?
              # Verify the connection is still usable after Thread#raise
              assert_equal i.to_s, dc.get("key:#{i}")
            end
          end
        end
      end

      it 'handles asynchronous Thread#raise during pipelined get' do
        with_nil_logger do
          memcached(p, 19_191) do |dc|
            10.times do |i|
              expected_response = 100.times.to_h { |x| ["key:#{i}:#{x}", x.to_s] }
              expected_response.each do |key, val|
                dc.set(key, val)
              end

              thread = Thread.new do
                loop do
                  assert_equal expected_response, dc.get_multi(expected_response.keys)
                end
              rescue RuntimeError
                nil # expected
              end
              thread.join(rand(0.01..0.2))

              thread.raise('Test Timeout Error')
              joined_thread = thread.join(1)

              refute_nil joined_thread
              refute_predicate joined_thread, :alive?
              assert_equal expected_response, dc.get_multi(expected_response.keys)
            end
          end
        end
      end

      it 'handles asynchronous Thread#kill' do
        with_nil_logger do
          memcached(p, 19_191) do |dc|
            10.times do |i|
              thread = Thread.new do
                loop do
                  assert_instance_of Integer, dc.set("key:#{i}", i.to_s)
                end
              rescue RuntimeError
                nil # expected
              end
              thread.join(rand(0.01..0.2))

              thread.kill
              joined_thread = thread.join(1)

              refute_nil joined_thread
              refute_predicate joined_thread, :alive?
              assert_equal i.to_s, dc.get("key:#{i}")
            end
          end
        end
      end

      it 'handles asynchronous Thread#kill during pipelined get' do
        with_nil_logger do
          memcached(p, 19_191) do |dc|
            10.times do |i|
              expected_response = 100.times.to_h { |x| ["key:#{i}:#{x}", x.to_s] }
              expected_response.each do |key, val|
                dc.set(key, val)
              end

              thread = Thread.new do
                loop do
                  assert_equal expected_response, dc.get_multi(expected_response.keys)
                end
              rescue RuntimeError
                nil # expected
              end
              thread.join(rand(0.01..0.2))

              thread.kill
              joined_thread = thread.join(1)

              refute_nil joined_thread
              refute_predicate joined_thread, :alive?
              assert_equal expected_response, dc.get_multi(expected_response.keys)
            end
          end
        end
      end

      it 'passes a simple smoke test on a TCP socket' do
        memcached_persistent(p) do |dc, port|
          resp = dc.flush

          refute_nil resp
          assert_equal [true, true], resp

          assert op_addset_succeeds(dc.set(:foo, 'bar'))
          assert_equal 'bar', dc.get(:foo)

          resp = dc.get('123')

          assert_nil resp

          assert op_addset_succeeds(dc.set('123', 'xyz'))

          resp = dc.get('123')

          assert_equal 'xyz', resp

          assert op_addset_succeeds(dc.set('123', 'abc'))

          dc.prepend('123', '0')
          dc.append('123', '0')

          assert_raises Dalli::UnmarshalError do
            resp = dc.get('123')
          end

          dc.close
          dc = nil

          dc = Dalli::Client.new("localhost:#{port}", digest_class: OpenSSL::Digest::SHA1)

          assert op_addset_succeeds(dc.set('456', 'xyz', 0, raw: true))

          resp = dc.prepend '456', '0'

          assert resp

          resp = dc.append '456', '9'

          assert resp

          resp = dc.get('456', raw: true)

          assert_equal '0xyz9', resp

          assert op_addset_succeeds(dc.set('456', false))

          resp = dc.get('456')

          refute resp

          resp = dc.stats

          assert_instance_of Hash, resp

          dc.close
        end
      end

      it 'passes a simple smoke test on unix socket' do
        memcached_persistent(:meta, MemcachedMock::UNIX_SOCKET_PATH) do |dc, path|
          resp = dc.flush

          refute_nil resp
          assert_equal [true], resp

          assert op_addset_succeeds(dc.set(:foo, 'bar'))
          assert_equal 'bar', dc.get(:foo)

          resp = dc.get('123')

          assert_nil resp

          assert op_addset_succeeds(dc.set('123', 'xyz'))

          resp = dc.get('123')

          assert_equal 'xyz', resp

          assert op_addset_succeeds(dc.set('123', 'abc'))

          dc.prepend('123', '0')
          dc.append('123', '0')

          assert_raises Dalli::UnmarshalError do
            resp = dc.get('123')
          end

          dc.close
          dc = nil

          dc = Dalli::Client.new(path)

          assert op_addset_succeeds(dc.set('456', 'xyz', 0, raw: true))

          resp = dc.prepend '456', '0'

          assert resp

          resp = dc.append '456', '9'

          assert resp

          resp = dc.get('456', raw: true)

          assert_equal '0xyz9', resp

          assert op_addset_succeeds(dc.set('456', false))

          resp = dc.get('456')

          refute resp

          resp = dc.stats

          assert_instance_of Hash, resp

          dc.close
        end
      end
    end
  end

  if MemcachedManager.supported_protocols.include?(:meta)
    describe 'ServerError' do
      it 'is raised when Memcached response with a SERVER_ERROR' do
        memcached_mock(->(sock) { sock.write("SERVER_ERROR foo bar\r\n") }) do
          dc = Dalli::Client.new('localhost:19123', protocol: :meta)
          err = assert_raises Dalli::ServerError do
            dc.get('abc')
          end

          assert_equal 'SERVER_ERROR foo bar', err.message
        end
      end
    end
  end

  describe 'fixed-length reads' do
    # Regression test for truncated reads: a peer that closes the connection
    # partway through a response body must not surface a decodable-but-wrong
    # value. The dirty socket must be closed and the request retried on a
    # fresh connection.
    it 'does not return a truncated value when the peer closes mid-response body' do
      value = 'a' * 512
      tcp_server = TCPServer.new('127.0.0.1', 0)
      port = tcp_server.addr[1]
      get_count = 0
      get_count_mutex = Mutex.new

      server_thread = Thread.new do
        loop do
          conn = tcp_server.accept
          Thread.new(conn) do |c|
            while (line = c.gets("\r\n"))
              cmd, key = line.split
              case cmd
              when 'version'
                c.write("VERSION 1.6.39-fake\r\n")
              when 'mg'
                nth = get_count_mutex.synchronize { get_count += 1 }
                if nth == 1
                  # Correct header + length, only part of the body, then EOF.
                  c.write("VA #{value.bytesize} k#{key}\r\n")
                  c.write(value[0, value.bytesize - 16])
                  c.close
                  break
                else
                  c.write("VA #{value.bytesize} k#{key}\r\n#{value}\r\n")
                end
              else
                c.write("ERROR\r\n")
              end
            end
          rescue IOError, Errno::ECONNRESET, Errno::EPIPE
            nil
          end
        rescue IOError
          next
        end
      end
      server_thread.abort_on_exception = true

      begin
        dc = Dalli::Client.new("127.0.0.1:#{port}", raw: true, socket_timeout: 2, socket_max_failures: 2)
        conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

        assert_equal value, dc.get('trunc_key'),
                     'a mid-response EOF must not surface a truncated value'
        assert_equal 2, get_count,
                     'the truncated first response should trigger a transparent retry'
        refute_predicate conn_mgr, :request_in_progress?
      ensure
        tcp_server.close
        server_thread.kill
      end
    end
  end

  # A request whose reply is lost may still have been applied, so only a
  # request that is safe to apply twice is sent again. Each case runs with the
  # reply delayed past socket_timeout and with the connection closed instead.
  # Where reads don't time out (JRuby, TruffleRuby, Ruby 3.1), the delayed
  # reply shows up as the connection closing once the delay is over, which
  # is still a failure after the request was sent.
  describe 'when a reply is lost after the request was sent' do
    lost_reply_modes = { 'delayed past socket_timeout' => 0.6, 'cut off by a closed connection' => 0 }

    def with_lost_reply(upstream_port, lose:, delay:, client_options: {}, **proxy_options)
      proxy = ReplyLosingProxy.new(upstream_port, lose: lose, delay: delay, **proxy_options)
      dc = Dalli::Client.new("127.0.0.1:#{proxy.port}",
                             { socket_timeout: 0.2, socket_failure_delay: 0 }.merge(client_options))
      with_nil_logger { yield dc, proxy }
    ensure
      dc&.close
      proxy&.close
    end

    def command_named(command)
      ->(line) { line.split.first == command }
    end

    def assert_not_retried(&)
      err = assert_raises(Dalli::NetworkError, &)

      refute_kind_of Dalli::RetryableNetworkError, err
      assert_match(/may have been applied/, err.message)
    end

    lost_reply_modes.each do |mode, delay|
      describe mode do
        it 'raises from incr instead of applying it twice' do
          memcached_persistent do |direct, port|
            key = "incr-#{SecureRandom.hex(4)}"
            direct.set(key, '10', 0, raw: true)

            with_lost_reply(port, lose: command_named('ma'), delay: delay) do |dc, proxy|
              assert_not_retried { dc.incr(key, 1) }
              assert_equal 1, proxy.count('ma')
            end

            assert_equal '11', direct.get(key, raw: true)
          end
        end

        it 'retries get and returns the value' do
          memcached_persistent do |direct, port|
            key = "get-#{SecureRandom.hex(4)}"
            direct.set(key, 'value')

            with_lost_reply(port, lose: command_named('mg'), delay: delay) do |dc, proxy|
              assert_equal 'value', dc.get(key)
              assert_equal 2, proxy.count('mg')
            end
          end
        end

        it 'retries a set without a CAS' do
          memcached_persistent do |direct, port|
            key = "set-#{SecureRandom.hex(4)}"

            with_lost_reply(port, lose: command_named('ms'), delay: delay) do |dc, proxy|
              assert op_addset_succeeds(dc.set(key, 'value'))
              assert_equal 2, proxy.count('ms')
            end

            assert_equal 'value', direct.get(key)
          end
        end

        it 'raises from add instead of returning false for an add that succeeded' do
          memcached_persistent do |direct, port|
            key = "add-#{SecureRandom.hex(4)}"

            with_lost_reply(port, lose: command_named('ms'), delay: delay) do |dc, proxy|
              assert_not_retried { dc.add(key, 'value') }
              assert_equal 1, proxy.count('ms')
            end

            assert_equal 'value', direct.get(key)
          end
        end

        # Each sends a single request whose reply is lost
        {
          'decr' => ['ma', ->(direct, key) { direct.set(key, '19', 0, raw: true) },
                     ->(dc, key) { dc.decr(key, 1) }, '18'],
          'append' => ['ms', ->(direct, key) { direct.set(key, 'a', 0, raw: true) },
                       ->(dc, key) { dc.append(key, 'b') }, 'ab'],
          'prepend' => ['ms', ->(direct, key) { direct.set(key, 'a', 0, raw: true) },
                        ->(dc, key) { dc.prepend(key, 'b') }, 'ba'],
          'replace' => ['ms', ->(direct, key) { direct.set(key, 'old', 0, raw: true) },
                        ->(dc, key) { dc.replace(key, 'new', 0, raw: true) }, 'new'],
          'set_cas' => ['ms', ->(direct, key) { direct.set(key, 'old', 0, raw: true) },
                        ->(dc, key) { dc.set_cas(key, 'new', dc.get_cas(key, raw: true).last, 0, raw: true) }, 'new'],
          'replace_cas' => ['ms', ->(direct, key) { direct.set(key, 'old', 0, raw: true) },
                            lambda { |dc, key|
                              dc.replace_cas(key, 'new', dc.get_cas(key, raw: true).last, 0, raw: true)
                            }, 'new'],
          'delete_cas' => ['md', ->(direct, key) { direct.set(key, 'old', 0, raw: true) },
                           ->(dc, key) { dc.delete_cas(key, dc.get_cas(key, raw: true).last) }, nil],
          'cas' => ['ms', ->(direct, key) { direct.set(key, 'old', 0, raw: true) },
                    ->(dc, key) { dc.cas(key, 0, raw: true) { 'new' } }, 'new']
        }.each do |name, (command, setup, call, expected)|
          it "raises from #{name} instead of retrying it" do
            memcached_persistent do |direct, port|
              key = "#{name}-#{SecureRandom.hex(4)}"
              setup.call(direct, key)

              with_lost_reply(port, lose: command_named(command), delay: delay) do |dc, proxy|
                assert_not_retried { call.call(dc, key) }
                assert_equal 1, proxy.count(command)
              end

              value = direct.get(key, raw: true)
              expected ? assert_equal(expected, value) : assert_nil(value)
            end
          end
        end

        # A key that needs base64 encoding with an initial value is an incr
        # that misses, then an add. The add's reply is lost here; sending the
        # incr again would find the counter and add the amount to it.
        it 'does not replay an incr with an initial value for a base64-encoded key' do
          memcached_persistent do |direct, port|
            key = "counter #{SecureRandom.hex(4)}"

            with_lost_reply(port, lose: command_named('ms'), delay: delay) do |dc, proxy|
              assert_not_retried { dc.incr(key, 1, 0, 5) }
              assert_equal 1, proxy.count('ma')
              assert_equal 1, proxy.count('ms')
            end

            assert_equal '5', direct.get(key, raw: true)
          end
        end

        it 'raises from fetch_with_lock instead of losing the recache race it won' do
          memcached_persistent do |_direct, port|
            key = "lock-#{SecureRandom.hex(4)}"

            with_lost_reply(port, lose: command_named('mg'), delay: delay) do |dc, proxy|
              assert_not_retried { dc.fetch_with_lock(key) { flunk 'the block ran' } }
              assert_equal 1, proxy.count('mg')
            end
          end
        end
      end
    end

    # Connecting happens in Server#alive?, which retries a failed attempt
    # itself, so these two failures never reach the request
    it 'retries an incr when the connection closes while connecting' do
      memcached_persistent do |direct, port|
        key = "incr-#{SecureRandom.hex(4)}"
        direct.set(key, '10', 0, raw: true)

        with_lost_reply(port, lose: ->(_line) { false }, delay: 0, drop_first_connection: true) do |dc, proxy|
          assert_equal 11, dc.incr(key, 1)
          assert_equal 1, proxy.count('ma')
        end

        assert_equal '11', direct.get(key, raw: true)
      end
    end

    it 'retries an incr when connecting is refused once' do
      memcached_persistent do |direct, port|
        key = "incr-#{SecureRandom.hex(4)}"
        direct.set(key, '10', 0, raw: true)
        dc = Dalli::Client.new("127.0.0.1:#{port}", socket_failure_delay: 0)
        attempts = 0
        open = Dalli::Socket::TCP.method(:open)
        refuse_once = lambda do |*args|
          attempts += 1
          raise Errno::ECONNREFUSED if attempts == 1

          open.call(*args)
        end

        with_nil_logger do
          Dalli::Socket::TCP.stub(:open, refuse_once) { assert_equal 11, dc.incr(key, 1) }
        end

        assert_equal 2, attempts
        assert_equal '11', direct.get(key, raw: true)
      ensure
        dc&.close
      end
    end

    # With defer_drain, an earlier quiet block's replies are read with a noop
    # before the incr is written, so a failure there comes before the incr
    # was sent
    it 'retries an incr when draining an earlier quiet block fails' do
      memcached_persistent do |direct, port|
        key = "incr-#{SecureRandom.hex(4)}"
        quiet_key = "quiet-#{SecureRandom.hex(4)}"
        direct.set(key, '10', 0, raw: true)

        with_lost_reply(port, lose: command_named('mn'), delay: 0, client_options: { defer_drain: true }) do |dc, proxy|
          dc.quiet { dc.set(quiet_key, 'value') }

          assert_equal 11, dc.incr(key, 1)
          assert_equal 1, proxy.count('ma')
          assert_equal 1, proxy.count('ms')
        end

        assert_equal '11', direct.get(key, raw: true)
        assert_equal 'value', direct.get(quiet_key)
      end
    end
  end
end
