# frozen_string_literal: true

require 'openssl'
require 'rbconfig'

module Dalli
  ##
  # Various socket implementations used by Dalli.
  ##
  module Socket
    ##
    # Common methods for all socket implementations.
    ##
    module InstanceMethods
      WAIT_RCS = %i[wait_writable wait_readable].freeze
      def read_available
        value = +''
        loop do
          result = read_nonblock(8196, exception: false)
          break if WAIT_RCS.include?(result)
          raise Errno::ECONNRESET, "Connection reset: #{logged_options.inspect}" unless result

          value << result
        end
        value
      end

      FILTERED_OUT_OPTIONS = %i[username password].freeze
      def logged_options
        options.reject { |k, _| FILTERED_OUT_OPTIONS.include? k }
      end
    end

    ##
    # Wraps the below TCP socket class in the case where the client
    # has configured a TLS/SSL connection between Dalli and the
    # Memcached server.
    ##
    class SSLSocket < ::OpenSSL::SSL::SSLSocket
      include Dalli::Socket::InstanceMethods
      def options
        io.options
      end

      unless method_defined?(:wait_readable)
        def wait_readable(timeout = nil)
          to_io.wait_readable(timeout)
        end
      end

      unless method_defined?(:wait_writable)
        def wait_writable(timeout = nil)
          to_io.wait_writable(timeout)
        end
      end
    end

    ##
    # A standard TCP socket between the Dalli client and the Memcached server.
    ##
    class TCP < TCPSocket
      include Dalli::Socket::InstanceMethods
      # options - supports enhanced logging in the case of a timeout
      attr_accessor :options

      def self.open(host, port, options = {})
        create_socket_with_timeout(host, port, options) do |sock|
          sock.options = { host: host, port: port }.merge(options)
          init_socket_options(sock, options)

          options[:ssl_context] ? wrapping_ssl_socket(sock, host, options[:ssl_context]) : sock
        end
      end

      def self.create_socket_with_timeout(host, port, options)
        # Check that TCPSocket#initialize was not overwritten by resolv-replace gem
        # (part of ruby standard library since 3.0.0, should be removed in 3.4.0),
        # as it does not handle keyword arguments correctly.
        # To check this we are using the fact that resolv-replace
        # aliases TCPSocket#initialize method to #original_resolv_initialize.
        # https://github.com/ruby/resolv-replace/blob/v0.1.1/lib/resolv-replace.rb#L21
        if RUBY_VERSION >= '3.0' &&
           !::TCPSocket.private_instance_methods.include?(:original_resolv_initialize)
          sock = new(host, port, connect_timeout: options[:socket_timeout])
          yield(sock)
        else
          Timeout.timeout(options[:socket_timeout]) do
            sock = new(host, port)
            yield(sock)
          end
        end
      end

      def self.init_socket_options(sock, options)
        configure_tcp_options(sock, options)
        configure_socket_buffers(sock, options)
        configure_timeout(sock, options)
      end

      def self.configure_tcp_options(sock, options)
        sock.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, true)
        sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true) if options[:keepalive]
      end

      def self.configure_socket_buffers(sock, options)
        sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVBUF, options[:rcvbuf]) if options[:rcvbuf]
        sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDBUF, options[:sndbuf]) if options[:sndbuf]
      end

      def self.configure_timeout(sock, options)
        return unless options[:socket_timeout]

        if sock.respond_to?(:timeout=)
          sock.timeout = options[:socket_timeout]
        else
          seconds, fractional = options[:socket_timeout].divmod(1)
          timeval = [seconds, fractional * 1_000_000].pack('l_2')

          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO, timeval)
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDTIMEO, timeval)
        end
      end

      def self.wrapping_ssl_socket(tcp_socket, host, ssl_context)
        ssl_socket = Dalli::Socket::SSLSocket.new(tcp_socket, ssl_context)
        ssl_socket.hostname = host
        ssl_socket.sync_close = true
        ssl_socket.connect
        ssl_socket
      end
    end

    if /mingw|mswin/.match?(RbConfig::CONFIG['host_os'])
      ##
      # UNIX domain sockets are not supported on Windows platforms.
      ##
      class UNIX
        def initialize(*_args)
          raise Dalli::DalliError, 'Unix sockets are not supported on Windows platform.'
        end
      end
    else

      ##
      # UNIX represents a UNIX domain socket, which is an interprocess communication
      # mechanism between processes on the same host.  Used when the Memcached server
      # is running on the same machine as the Dalli client.
      ##
      class UNIX < UNIXSocket
        include Dalli::Socket::InstanceMethods

        # options - supports enhanced logging in the case of a timeout
        # server  - used to support IO.select in the pipelined getter
        attr_accessor :options

        def self.open(path, options = {})
          Timeout.timeout(options[:socket_timeout]) do
            sock = new(path)
            sock.options = { path: path }.merge(options)
            init_socket_options(sock, options)
            sock
          end
        end

        def self.init_socket_options(sock, options)
          # https://man7.org/linux/man-pages/man7/unix.7.html
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDBUF, options[:sndbuf]) if options[:sndbuf]
          sock.timeout = options[:socket_timeout] if options[:socket_timeout] && sock.respond_to?(:timeout=)
        end
      end
    end
  end
end
