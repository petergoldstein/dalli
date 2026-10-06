# frozen_string_literal: true

require_relative '../helper'

describe 'Network' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'assuming a bad network' do
        it 'handle no server available' do
          dc = Dalli::Client.new 'localhost:19333'
          assert_raises Dalli::RingError, message: 'No server available' do
            dc.get 'foo'
          end
        end

        # On this line the meta protocol's line reads rely on SO_RCVTIMEO,
        # which some Rubies and platforms ignore, so a silent server can block
        # the read itself rather than exercising the retries. Binary only.
        if p == :binary
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

            # The ring reports a server it has marked down as a RingError
            assert_raises(Dalli::NetworkError, Dalli::RingError) { dc.get('anykey') }
            assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
          ensure
            server&.close
            acceptor&.kill
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
              assert_raises Dalli::RingError, message: 'No server available' do
                dc.get('abc')
              end
            end
          end

          it 'handle connection reset with unix socket' do
            socket_path = MemcachedMock::UNIX_SOCKET_PATH
            memcached_mock(lambda(&:close), :start_unix, socket_path) do
              dc = Dalli::Client.new(socket_path)
              assert_raises Dalli::RingError, message: 'No server available' do
                dc.get('abc')
              end
            end
          end

          it 'handle malformed response' do
            memcached_mock(->(sock) { sock.write('123') }) do
              dc = Dalli::Client.new('localhost:19123')
              assert_raises Dalli::RingError, message: 'No server available' do
                dc.get('abc')
              end
            end
          end

          it 'handle socket timeouts' do
            dc = Dalli::Client.new('localhost:19123', socket_timeout: 0)
            assert_raises Dalli::RingError, message: 'No server available' do
              dc.get('abc')
            end
          end

          it 'handle connect timeouts' do
            memcached_mock(lambda { |sock|
                             sleep(0.6)
                             sock.close
                           }, :delayed_start) do
              dc = Dalli::Client.new('localhost:19123')
              assert_raises Dalli::RingError, message: 'No server available' do
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
              assert_raises Dalli::RingError, message: 'No server available' do
                dc.get('abc')
              end
            end
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

      it 'handles asynchronous Thread#raise' do
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

              thread.raise('Test Timeout Error')
              joined_thread = thread.join(1)

              refute_nil joined_thread
              refute_predicate joined_thread, :alive?
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
        memcached_persistent(:binary, MemcachedMock::UNIX_SOCKET_PATH) do |dc, path|
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
end
