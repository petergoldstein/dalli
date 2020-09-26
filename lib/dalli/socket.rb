# frozen_string_literal: true

module Dalli
  module Socket

    module InstanceMethods
      def readfull(count)
        value = String.new('')
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
        value = String.new('')
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
        options.reject{|k,v| [:username, :password].include? k}
      end
    end

    class TCP < TCPSocket
      include Dalli::Socket::InstanceMethods
      attr_accessor :options, :server

      def self.open(host, port, server, options = {})
        Timeout.timeout(options[:socket_timeout]) do
          sock = new(host, port)
          sock.options = {:host => host, :port => port}.merge(options)
          sock.server = server
          sock.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, true)
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true) if options[:keepalive]
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVBUF, options[:rcvbuf]) if options[:rcvbuf]
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDBUF, options[:sndbuf]) if options[:sndbuf]
          sock
        end
      end
    end

    class UNIX < UNIXSocket
      include Dalli::Socket::InstanceMethods
      attr_accessor :options, :server

      def self.open(path, server, options = {})
        Timeout.timeout(options[:socket_timeout]) do
          sock = new(path)
          sock.options = {:path => path}.merge(options)
          sock.server = server
          sock
        end
      end
    end
  end
end
