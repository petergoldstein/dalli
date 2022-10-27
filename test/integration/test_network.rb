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

        describe 'with a fake server' do
          it 'handle connection reset' do
            memcached_mock(->(sock) { sock.close }) do
              dc = Dalli::Client.new('localhost:19123')
              assert_raises Dalli::RingError, message: 'No server available' do
                dc.get('abc')
              end
            end
          end

          it 'handle connection reset with unix socket' do
            socket_path = MemcachedMock::UNIX_SOCKET_PATH
            memcached_mock(->(sock) { sock.close }, :start_unix, socket_path) do
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
            assert_equal Dalli::Socket::TCP, sock.class

            dc.set('abc', 123)
            assert_equal(123, dc.get('abc'))
          end
        end

        it 'opens a SSL TCP connection when there is an SSL context set' do
          memcached_ssl_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            sock = Dalli::Socket::TCP.open(server.hostname, server.port, server.options)
            assert_equal Dalli::Socket::SSLSocket, sock.class

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

          dc = Dalli::Client.new("localhost:#{port}", digest_class: ::OpenSSL::Digest::SHA1)

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
          assert_equal Hash, resp.class

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
          assert_equal Hash, resp.class

          dc.close
        end
      end
    end
  end
end
