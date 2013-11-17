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