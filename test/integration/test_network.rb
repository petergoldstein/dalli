# frozen_string_literal: true

require_relative '../helper'

describe 'Network' do
  describe 'assuming a bad network' do
    it 'handle no server available' do
      dc = Dalli::Client.new 'localhost:19333'
      assert_raises Dalli::RingError, message: 'No server available' do
        dc.get 'foo'
      end
    end

    it 'handle connection reset' do
      toxi_memcached_persistent do |dc|
        Toxiproxy[/dalli_memcached/].down do
          assert_raises Dalli::RingError, message: 'No server available' do
            dc.get('abc')
          end
        end
      end
    end

    it 'handles socket timeouts' do
      toxi_memcached_persistent(MemcachedManager::TOXIPROXY_UPSTREAM_PORT, '', { socket_timeout: 1 }) do |dc|
        dc.close
        dc.flush

        dc.set('foo', 'bar')

        assert_equal('bar', dc.get('foo'))

        Toxiproxy[/dalli_memcached/].downstream(:latency, latency: 2000).apply do
          assert_raises Dalli::RingError, message: 'No server available' do
            dc.get('abc')
          end
        end
      end
    end

    it 'handle connect timeouts' do
      toxi_memcached_persistent(MemcachedManager::TOXIPROXY_UPSTREAM_PORT, '', { socket_timeout: 1 }) do |dc|
        dc.close

        Toxiproxy[/dalli_memcached/].downstream(:latency, latency: 2000).apply do
          assert_raises Dalli::RingError, message: 'No server available' do
            dc.get('abc')
          end
        end
      end
    end
  end

  it 'opens a standard TCP connection when ssl_context is not configured' do
    memcached_persistent do |dc|
      server = dc.send(:ring).servers.first
      sock = Dalli::Socket::TCP.open(server.hostname, server.port, server.options)

      assert_instance_of Dalli::Socket::TCP, sock

      dc.set('abc', 123)

      assert_equal(123, dc.get('abc'))
    end
  end

  it 'opens a SSL TCP connection when there is an SSL context set' do
    memcached_ssl_persistent do |dc|
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
    memcached_persistent do |_, port|
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

  it 'handles timeout error during pipelined get' do
    with_nil_logger do
      memcached(19_191) do |dc|
        dc.send(:ring).server_for_key('abc').sock.stub(:write, proc { raise Timeout::Error }) do
          assert_empty dc.get_multi(['abc'])
        end
      end
    end
  end

  it 'handles asynchronous Thread#raise' do
    with_nil_logger do
      memcached(19_191) do |dc|
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
      memcached(19_191) do |dc|
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
      memcached(19_191) do |dc|
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
      memcached(19_191) do |dc|
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
    memcached_persistent do |dc, port|
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
    memcached_persistent(MemcachedManager::UNIX_SOCKET_PATH) do |dc, path|
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
