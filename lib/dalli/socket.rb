begin
  require 'kgio'
  puts "Using kgio socket IO" if defined?($TESTING) && $TESTING

  class Dalli::Server::KSocket < Kgio::Socket
    attr_accessor :options

    def kgio_wait_readable
      IO.select([self], nil, nil, options[:timeout]) || raise(Timeout::Error, "IO timeout")
    end

    def kgio_wait_writable
      IO.select(nil, [self], nil, options[:timeout]) || raise(Timeout::Error, "IO timeout")
    end

    def self.open(host, port, options = {})
      addr = Socket.pack_sockaddr_in(port, host)
      sock = start(addr)
      sock.options = options
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

  end



  if ::Kgio.respond_to?(:wait_readable=)
    ::Kgio.wait_readable = :kgio_wait_readable
    ::Kgio.wait_writable = :kgio_wait_writable
  end

rescue LoadError

  puts "Using standard socket IO (#{RUBY_DESCRIPTION})" if defined?($TESTING) && $TESTING
  if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby'

    class Dalli::Server::KSocket < TCPSocket
      attr_accessor :options

      def self.open(host, port, options = {})
        sock = new(host, port)
        sock.options = { :host => host, :port => port }.merge(options)
        sock
      end

      def readfull(count)
        value = ''
        begin
          loop do
            value << read_nonblock(count - value.bytesize)
            break if value.bytesize == count
          end
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          if IO.select([self], nil, nil, options[:timeout])
            retry
          else
            raise Timeout::Error, "IO timeout: #{options.inspect}"
          end
        end
        value
      end

    end

  else

    class Dalli::Server::KSocket < Socket
      attr_accessor :options

      def self.open(host, port, options = {})
        # All this ugly code to ensure proper Socket connect timeout
        addr = Socket.getaddrinfo(host, nil)
        sock = new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)
        sock.options = { :host => host, :port => port }.merge(options)
        begin
          sock.connect_nonblock(Socket.pack_sockaddr_in(port, addr[0][3]))
        rescue Errno::EINPROGRESS
          resp = IO.select(nil, [sock], nil, sock.options[:timeout])
          begin
            sock.connect_nonblock(Socket.pack_sockaddr_in(port, addr[0][3]))
          rescue Errno::EISCONN
          end
        end
        sock
      end

      def readfull(count)
        value = ''
        begin
          loop do
            value << sysread(count - value.bytesize)
            break if value.bytesize == count
          end
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          if IO.select([self], nil, nil, options[:timeout])
            retry
          else
            raise Timeout::Error, "IO timeout: #{options.inspect}"
          end
        end
        value
      end
    end

  end
end

begin
  require 'em-synchrony'
  puts "Defining alternate em-synchrony socket IO" if defined?($TESTING) && $TESTING

  class Dalli::Server::AsyncSocket < EventMachine::Synchrony::TCPSocket
    # XXX. need to somehow implement the timeout option.
    # EM::Synchrony::TCPsocket does give you any timeouts. To implement it we'd have
    # to change that class to take a timeout parameter that it would then set on
    # the Deferrable objects it waits on.
    attr_accessor :options

    def self.open(host, port, options = {})
      sock = new(host, port)
      sock.options = { :host => host, :port => port }.merge(options)
      sock
    end

    def readfull(count)
      value = ''
      loop do
        value << read(count - value.bytesize)
        break if value.bytesize == count
      end
      value
    end

  end

rescue LoadError
  puts "Could not define alternate em-synchrony socket IO" if defined?($TESTING) && $TESTING
end

require 'rbconfig'
if RbConfig::CONFIG['host_os'] =~ /mingw|mswin/
  class Dalli::Server::USocket
    def initialize(*args)
      raise Dalli::DalliError, "Unix sockets are not supported on Windows platform."
    end
  end
else
  class Dalli::Server::USocket < UNIXSocket
    def readfull(count)
      value = ''
      loop do
        value << read(count - value.bytesize)
        break if value.bytesize == count
      end
      value
    end
  end
end
