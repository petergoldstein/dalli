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
      def read_available(reusable_buffer = nil)
        if reusable_buffer
          value = read_nonblock(8196, reusable_buffer, exception: false)
          case value
          when :wait_writable, :wait_readable
            return reusable_buffer.clear
          when nil
            raise Errno::ECONNRESET, "Connection reset: #{logged_options.inspect}"
          end
        else
          value = ''.b
        end

        buffer = ''.b
        loop do
          result = read_nonblock(8196, buffer, exception: false)
          case result
          when :wait_writable, :wait_readable
            buffer.clear
            return value
          when nil
            raise Errno::ECONNRESET, "Connection reset: #{logged_options.inspect}"
          else
            value << result
          end
        end
      end

      FILTERED_OUT_OPTIONS = %i[username password].freeze
      def logged_options
        options.except(*FILTERED_OUT_OPTIONS)
      end

      # JRuby doesn't support IO#timeout=, so use custom readfull implementation
      # CRuby 3.3+ has IO#timeout= which makes IO#read work with timeouts
      if RUBY_ENGINE == 'jruby'
        # rubocop:disable Metrics/AbcSize
        def readfull(count)
          value = String.new(capacity: count + 1)

          until value.bytesize == count
            result = read_nonblock(count - value.bytesize, exception: false)
            case result
            when :wait_readable
              wait_readable(options[:socket_timeout]) or raise Timeout::Error, "IO timeout: #{logged_options.inspect}"
            when :wait_writable
              wait_writable(options[:socket_timeout]) or raise Timeout::Error, "IO timeout: #{logged_options.inspect}"
            when nil
              raise Errno::ECONNRESET, "Connection reset: #{logged_options.inspect}"
            else
              value << result
            end
          end

          value
        end
        # rubocop:enable Metrics/AbcSize
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

      # Expected parameter signature for unmodified TCPSocket#initialize.
      # Used to detect when gems like socksify or resolv-replace have monkey-patched
      # TCPSocket, which breaks the connect_timeout: keyword argument.
      TCPSOCKET_NATIVE_PARAMETERS = [[:rest]].freeze
      private_constant :TCPSOCKET_NATIVE_PARAMETERS

      def self.open(host, port, options = {})
        create_socket_with_timeout(host, port, options) do |sock|
          sock.options = { host: host, port: port }.merge(options)
          init_socket_options(sock, options)

          options[:ssl_context] ? wrapping_ssl_socket(sock, host, options[:ssl_context]) : sock
        end
      end

      # Detect and cache whether TCPSocket supports the connect_timeout: keyword argument.
      # Returns true for an unmodified TCPSocket on Ruby 3.0+, or for resolv-replace >= 0.2.0
      # which forwards keyword arguments through its patch.
      # Returns false when monkey-patched by gems like socksify or resolv-replace < 0.2.0.
      # rubocop:disable ThreadSafety/ClassInstanceVariable
      def self.supports_connect_timeout?
        return @supports_connect_timeout if defined?(@supports_connect_timeout)

        @supports_connect_timeout = RUBY_ENGINE == 'ruby' && RUBY_VERSION >= '3.0' &&
                                    ::TCPSocket.instance_method(:initialize).parameters.then do |params|
                                      params == TCPSOCKET_NATIVE_PARAMETERS || params.any? do |type, _|
                                        type == :keyrest
                                      end
                                    end
      end
      # rubocop:enable ThreadSafety/ClassInstanceVariable

      def self.create_socket_with_timeout(host, port, options)
        if supports_connect_timeout?
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
          # Ruby 3.2+ has IO#timeout for reliable cross-platform timeout handling
          sock.timeout = options[:socket_timeout]
        else
          # Ruby 3.1 fallback using socket options
          # struct timeval has architecture-dependent sizes (time_t, suseconds_t)
          seconds, fractional = options[:socket_timeout].divmod(1)
          microseconds = (fractional * 1_000_000).to_i
          timeval = pack_timeval(sock, seconds, microseconds)

          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO, timeval)
          sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDTIMEO, timeval)
        end
      end

      # Pack formats for struct timeval across architectures.
      # Uses fixed-size formats for JRuby compatibility (JRuby doesn't support _ modifier on q).
      # - ll: 8 bytes (32-bit time_t, 32-bit suseconds_t)
      # - qq: 16 bytes (64-bit time_t, 64-bit suseconds_t or padded 32-bit)
      TIMEVAL_PACK_FORMATS = %w[ll qq].freeze
      TIMEVAL_TEST_VALUES = [0, 0].freeze

      # Detect and cache the correct pack format for struct timeval on this platform.
      # Different architectures have different sizes for time_t and suseconds_t.
      # rubocop:disable ThreadSafety/ClassInstanceVariable
      def self.timeval_pack_format(sock)
        @timeval_pack_format ||= begin
          expected_size = sock.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO).data.bytesize
          TIMEVAL_PACK_FORMATS.find { |fmt| TIMEVAL_TEST_VALUES.pack(fmt).bytesize == expected_size } || 'll'
        end
      end
      # rubocop:enable ThreadSafety/ClassInstanceVariable

      def self.pack_timeval(sock, seconds, microseconds)
        [seconds, microseconds].pack(timeval_pack_format(sock))
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
