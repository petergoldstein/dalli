begin
  require 'kgio'
  puts "Using kgio socket IO" if defined?($TESTING) && $TESTING

  class Dalli::Server::KSocket < Kgio::Socket
    attr_accessor :options, :server

    def kgio_wait_readable
      IO.select([self], nil, nil, options[:socket_timeout]) || raise(Timeout::Error, "IO timeout")
    end

    def kgio_wait_writable
      IO.select(nil, [self], nil, options[:socket_timeout]) || raise(Timeout::Error, "IO timeout")
    end

    def self.open(host, port, server, options = {})
      addr = Socket.pack_sockaddr_in(port, host)
      sock = start(addr)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true) if options[:keepalive]
      sock.options = options
      sock.server = server
      sock.kgio_wait_writable
      sock
    end

    alias :write :kgio_write

    def readfull(count)
      value = ''
      loop do
        value << kgio_read!(count - value.bytesize)
        break if value.bytesize == count
      end
      value
    end

    def read_available
      value = ''
      loop do
        ret = kgio_tryread(8196)
        case ret
        when nil
          raise EOFError, 'end of stream'
        when :wait_readable
          break
        else
          value << ret
        end
      end
      value
    end

  end

  if ::Kgio.respond_to?(:wait_readable=)
    ::Kgio.wait_readable = :kgio_wait_readable
    ::Kgio.wait_writable = :kgio_wait_writable
  end

rescue LoadError

  puts "Using standard socket IO (#{RUBY_DESCRIPTION})" if defined?($TESTING) && $TESTING
  class Dalli::Server::KSocket < TCPSocket
    attr_accessor :options, :server

    def self.open(host, port, server, options = {})
      Timeout.timeout(options[:socket_timeout]) do
        sock = new(host, port)
        sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true) if options[:keepalive]
        sock.options = { :host => host, :port => port }.merge(options)
        sock.server = server
        sock
      end
    end

    def readfull(count)
      value = ''
      begin
        loop do
          value << read_nonblock(count - value.bytesize)
          break if value.bytesize == count
        end
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK
        if IO.select([self], nil, nil, options[:socket_timeout])
          retry
        else
          raise Timeout::Error, "IO timeout: #{options.inspect}"
        end
      end
      value
    end

    def read_available
      value = ''
      loop do
        begin
          value << read_nonblock(8196)
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          break
        end
      end
      value
    end

  end
end
