# frozen_string_literal: true

require 'openssl'
require 'rbconfig'

module Dalli
  module Socket
    module InstanceMethods

      def readfull(count)
        value = +""
        loop do
          result = read_nonblock(count - value.bytesize, exception: false)
          if result == :wait_readable
            raise Timeout::Error, "IO timeout: #{safe_options.inspect}" unless IO.select([self], nil, nil, options[:socket_timeout])
          elsif result == :wait_writable
            raise Timeout::Error, "IO timeout: #{safe_options.inspect}" unless IO.select(nil, [self], nil, options[:socket_timeout])
          elsif result
            value << result
          else
            raise Errno::ECONNRESET, "Connection reset: #{safe_options.inspect}"
          end
          break if value.bytesize == count
        end
        value
      end

      def read_available
        value = +""
        loop do
          result = read_nonblock(8196, exception: false)
          if result == :wait_readable
            break
          elsif result == :wait_writable
            break
          elsif result
            value << result
          else
            raise Errno::ECONNRESET, "Connection reset: #{safe_options.inspect}"
          end
        end
        value
      end

      def safe_options
        options.reject { |k, v| [:username, :password].include? k }
      end
    end

    class SSLSocket < ::OpenSSL::SSL::SSLSocket
      include Dalli::Socket::InstanceMethods
      def options
        io.options
      end
    end

    class TCP < TCPSocket
      include Dalli::Socket::InstanceMethods
      attr_accessor :options, :server

      def self.open(host, port, server, options = {})
        Timeout.timeout(options[:socket_timeout]) do
          sock = new(host, port)
          sock.options = {host: host, port: port}.merge(options)
          sock.server = server
          sock.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, true)
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true) if options[:keepalive]
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVBUF, options[:rcvbuf]) if options[:rcvbuf]
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDBUF, options[:sndbuf]) if options[:sndbuf]

          return sock unless options[:ssl_context]

          ssl_socket = Dalli::Socket::SSLSocket.new(sock, options[:ssl_context])
          ssl_socket.hostname = host
          ssl_socket.sync_close = true
          ssl_socket.connect
          ssl_socket
        end
      end
    end
  end

  if RbConfig::CONFIG['host_os'] =~ /mingw|mswin/
    class Dalli::Socket::UNIX
      def initialize(*args)
        raise Dalli::DalliError, 'Unix sockets are not supported on Windows platform.'
      end
    end
  else
    class Dalli::Socket::UNIX < UNIXSocket
      include Dalli::Socket::InstanceMethods
      attr_accessor :options, :server

      def self.open(path, server, options = {})
        Timeout.timeout(options[:socket_timeout]) do
          sock = new(path)
          sock.options = {path: path}.merge(options)
          sock.server = server
          sock
        end
      end
    end
  end
end
