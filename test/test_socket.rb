# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli::Socket::TCP TLS handshake' do
  # A plain TCP server that answers every connection with a non-TLS reply and
  # hangs up, so the client's TLS handshake fails
  def with_garbage_server
    server = TCPServer.new('127.0.0.1', 0)
    acceptor = Thread.new { serve_garbage(server) }
    yield server.addr[1]
  ensure
    server&.close
    acceptor&.kill
    acceptor&.join
  end

  def serve_garbage(server)
    loop do
      sock = server.accept
      sock.write("ERROR not a TLS server\r\n" * 4)
      sock.close
    end
  rescue IOError, SystemCallError
    nil
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
    ssl_socket.define_singleton_method(:connect) { raise Timeout::Error, 'timed out' }

    with_nil_logger do
      Dalli::Socket::SSLSocket.stub(:new, ssl_socket) do
        assert_raises(Timeout::Error) do
          Dalli::Socket::TCP.wrapping_ssl_socket(tcp_socket, 'localhost', unverified_context)
        end
      end
    end
    tcp_socket.verify
  end

  describe 'verification warning' do
    before do
      Dalli::Socket::TCP.instance_variable_set(:@ssl_verification_warning_logged, false)
    end

    after do
      Dalli::Socket::TCP.instance_variable_set(:@ssl_verification_warning_logged, false)
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
