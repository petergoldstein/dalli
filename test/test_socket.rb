# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli::Socket::TCP' do
  describe '.supports_connect_timeout?' do
    before do
      # Clear the cached value before each test
      Dalli::Socket::TCP.remove_instance_variable(:@supports_connect_timeout) if
        Dalli::Socket::TCP.instance_variable_defined?(:@supports_connect_timeout)
    end

    def with_tcpsocket_parameters(params, &block)
      fake_method = Object.new
      fake_method.define_singleton_method(:parameters) { params }
      TCPSocket.stub(:instance_method, fake_method, &block)
    end

    it 'returns true for unmodified TCPSocket on MRI Ruby 3.0+' do
      skip 'Ruby 3.0+ required' if RUBY_VERSION < '3.0'
      skip 'MRI-specific test' if RUBY_ENGINE != 'ruby'

      # Assuming TCPSocket hasn't been monkey-patched in test environment
      # TruffleRuby and JRuby have different TCPSocket#initialize signatures
      assert_predicate Dalli::Socket::TCP, :supports_connect_timeout?
    end

    it 'returns false for Ruby < 3.0' do
      skip 'Only testable on Ruby < 3.0' if RUBY_VERSION >= '3.0'

      refute_predicate Dalli::Socket::TCP, :supports_connect_timeout?
    end

    it 'caches the result' do
      # First call
      result1 = Dalli::Socket::TCP.supports_connect_timeout?

      # Verify it's cached
      assert Dalli::Socket::TCP.instance_variable_defined?(:@supports_connect_timeout)

      # Second call should return same value
      result2 = Dalli::Socket::TCP.supports_connect_timeout?

      assert_equal result1, result2
    end

    it 'returns true for resolv-replace >= 0.2.0 which forwards keyword arguments' do
      skip 'Ruby 3.0+ required' if RUBY_VERSION < '3.0'
      skip 'MRI-specific test' if RUBY_ENGINE != 'ruby'

      # resolv-replace >= 0.2.0 uses def initialize(host, serv, *rest, **kwargs)
      params = [%i[req host], %i[req serv], %i[rest rest], %i[keyrest kwargs]]

      with_tcpsocket_parameters(params) do
        assert_predicate Dalli::Socket::TCP, :supports_connect_timeout?
      end
    end

    it 'returns false for resolv-replace < 0.2.0 which does not forward keyword arguments' do
      skip 'Ruby 3.0+ required' if RUBY_VERSION < '3.0'
      skip 'MRI-specific test' if RUBY_ENGINE != 'ruby'

      # resolv-replace < 0.2.0 uses def initialize(host, serv, *rest) - no kwargs
      params = [%i[req host], %i[req serv], %i[rest rest]]

      with_tcpsocket_parameters(params) do
        refute_predicate Dalli::Socket::TCP, :supports_connect_timeout?
      end
    end
  end

  describe '.create_socket_with_timeout' do
    it 'yields a socket when connection succeeds' do
      memcached(:meta, rand(21_500..21_600)) do |_, port|
        socket_yielded = false

        Dalli::Socket::TCP.create_socket_with_timeout('127.0.0.1', port, socket_timeout: 5) do |sock|
          socket_yielded = true

          assert_kind_of TCPSocket, sock
        end

        assert socket_yielded, 'Block should have been yielded to'
      end
    end

    it 'bounds DNS resolution as well as the connect by the socket timeout' do
      received = nil
      fake_new = lambda do |*args, **kwargs|
        received = [args, kwargs]
        :sock
      end

      Dalli::Socket::TCP.stub(:supports_connect_timeout?, true) do
        Dalli::Socket::TCP.stub(:new, fake_new) do
          Dalli::Socket::TCP.create_socket_with_timeout('cache.example.com', 11_211, socket_timeout: 0.5) { |_| nil }
        end
      end

      assert_equal [['cache.example.com', 11_211], { connect_timeout: 0.5, resolv_timeout: 0.5 }], received
    end

    it 'raises on connection timeout to non-existent server' do
      # Use a port that's unlikely to be listening
      assert_raises(Errno::ECONNREFUSED, Timeout::Error) do
        Dalli::Socket::TCP.create_socket_with_timeout('127.0.0.1', 59_999, socket_timeout: 1) do |_sock|
          flunk 'Should not yield socket for failed connection'
        end
      end
    end
  end
end

describe 'Dalli::Socket::InstanceMethods#read_available' do
  # Returns scripted read_nonblock results in order and counts the calls
  def scripted_socket(results, buffered: false)
    sock = Object.new
    sock.extend(Dalli::Socket::InstanceMethods)
    calls = 0
    sock.define_singleton_method(:read_nonblock) do |_len, buf = nil, exception: true|
      raise 'unexpected extra read' unless exception == false && calls < results.size

      calls += 1
      result = results[calls - 1]
      next result unless result.is_a?(String)

      buf ? buf.replace(result) : result
    end
    sock.define_singleton_method(:buffered_data?) { buffered }
    sock.define_singleton_method(:read_calls) { calls }
    sock
  end

  let(:full_chunk) { 'x' * Dalli::Socket::InstanceMethods::READ_CHUNK_SIZE }

  it 'stops after a short read instead of reading again for :wait_readable' do
    sock = scripted_socket(['short'])

    assert_equal 'short', sock.read_available(''.b)
    assert_equal 1, sock.read_calls
  end

  it 'keeps reading after a full chunk' do
    sock = scripted_socket([full_chunk, 'tail'])

    assert_equal "#{full_chunk}tail", sock.read_available(''.b)
    assert_equal 2, sock.read_calls
  end

  it 'keeps reading after a short read while data is still buffered in-process' do
    sock = scripted_socket(['part', :wait_readable], buffered: true)

    assert_equal 'part', sock.read_available
    assert_equal 2, sock.read_calls
  end

  it 'returns an empty buffer when nothing is available' do
    sock = scripted_socket([:wait_readable])

    assert_equal '', sock.read_available(''.b)
  end
end

describe 'Dalli::Socket::SSLSocket#read_available' do
  # A real SSLSocket instance (no connection) with scripted reads and
  # pending counts, so the class's own buffered_data? override is exercised
  def scripted_ssl_socket(reads, pendings)
    sock = Dalli::Socket::SSLSocket.allocate
    read_calls = 0
    sock.define_singleton_method(:read_nonblock) do |_len, _buf = nil, exception: true|
      raise 'unexpected extra read' unless exception == false && read_calls < reads.size

      read_calls += 1
      reads[read_calls - 1]
    end
    sock.define_singleton_method(:pending) { pendings.shift || 0 }
    sock.define_singleton_method(:read_calls) { read_calls }
    sock
  end

  it 'keeps reading after a short read while OpenSSL still has data buffered' do
    sock = scripted_ssl_socket(['part', 'rest', :wait_readable], [5, 0])

    assert_equal 'partrest', sock.read_available
    assert_equal 2, sock.read_calls
  end

  it 'stops after a short read once OpenSSL has nothing buffered' do
    sock = scripted_ssl_socket(['part'], [0])

    assert_equal 'part', sock.read_available
    assert_equal 1, sock.read_calls
  end
end

describe 'Dalli::Socket::TCP TLS handshake' do
  # A plain TCP server that answers every connection with a non-TLS reply and
  # hangs up, so the client's TLS handshake fails
  def with_garbage_server
    server = TCPServer.new('127.0.0.1', 0)
    acceptor = Thread.new do
      loop do
        sock = server.accept
        sock.write("ERROR not a TLS server\r\n" * 4)
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

  def unverified_context
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ctx
  end

  def open_fds
    Dir.children('/dev/fd').size
  end

  it 'closes the TCP socket when the handshake fails' do
    skip '/dev/fd is not available' unless Dir.exist?('/dev/fd')

    with_nil_logger do
      with_garbage_server do |port|
        # Without GC, a socket that isn't closed explicitly stays open
        GC.disable
        before = open_fds

        20.times do
          assert_raises(OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError) do
            Dalli::Socket::TCP.open('127.0.0.1', port, socket_timeout: 1, ssl_context: unverified_context)
          end
        end

        # Allows for the server's side of the last connection still being open
        assert_operator open_fds - before, :<=, 2
      ensure
        GC.enable
      end
    end
  end

  it 'closes the TCP socket when the handshake times out' do
    tcp_socket = Minitest::Mock.new
    tcp_socket.expect(:close, nil)
    ssl_socket = Object.new
    ssl_socket.define_singleton_method(:hostname=) { |_| nil }
    ssl_socket.define_singleton_method(:sync_close=) { |_| nil }
    ssl_socket.define_singleton_method(:connect) { raise IO::TimeoutError, 'timed out' }

    with_nil_logger do
      Dalli::Socket::SSLSocket.stub(:new, ssl_socket) do
        assert_raises(IO::TimeoutError) do
          Dalli::Socket::TCP.wrapping_ssl_socket(tcp_socket, 'localhost', unverified_context)
        end
      end
    end
    tcp_socket.verify
  end

  describe 'verification warning' do
    before do
      Dalli::Socket::TCP.class_variable_set(:@@ssl_verification_warning_logged, false) # rubocop:disable Style/ClassVars
    end

    after do
      Dalli::Socket::TCP.class_variable_set(:@@ssl_verification_warning_logged, false) # rubocop:disable Style/ClassVars
    end

    def capture_warnings
      io = StringIO.new
      old = Dalli.logger
      Dalli.logger = Logger.new(io)
      Dalli.logger.level = Logger::WARN
      yield
      io.string
    ensure
      Dalli.logger = old
    end

    def failed_open(port, ctx)
      Dalli::Socket::TCP.open('127.0.0.1', port, socket_timeout: 1, ssl_context: ctx)
    rescue OpenSSL::SSL::SSLError, SystemCallError, EOFError
      nil
    end

    it 'warns once when the context does not verify the certificate' do
      with_garbage_server do |port|
        output = capture_warnings do
          3.times { failed_open(port, OpenSSL::SSL::SSLContext.new) }
        end

        assert_equal 1, output.scan('SECURITY WARNING').size
        assert_match(/VERIFY_NONE/, output)
      end
    end

    it 'warns when the context verifies the certificate but not the hostname' do
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.verify_hostname = false
      with_garbage_server do |port|
        output = capture_warnings { failed_open(port, ctx) }

        assert_equal 1, output.scan('SECURITY WARNING').size
        assert_match(/verify_hostname/, output)
      end
    end

    it 'does not warn for a context that verifies the certificate and hostname' do
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true)
      with_garbage_server do |port|
        output = capture_warnings { failed_open(port, ctx) }

        refute_match(/SECURITY WARNING/, output)
      end
    end
  end
end
