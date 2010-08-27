require 'socket'

module Dalli
  class Server
    attr_accessor :hostname
    attr_accessor :port
    attr_accessor :weight
    
    def initialize(attribs)
      (@hostname, @port, @weight) = attribs.split(':')
      @port ||= 11211
      @port = Integer(@port)
      @weight ||= 1
      @weight = Integer(@weight)
      connection
      Dalli.logger.debug { "#{@hostname}:#{@port} running memcached v#{request(:version)}" }
    end
    
    # Chokepoint method for instrumentation
    def request(op, *args)
      begin
        send(op, *args)
      rescue Dalli::NetworkError
        raise
      rescue Dalli::DalliError
        raise
      rescue Exception => ex
        Dalli.logger.error "Unexpected exception in Dalli: #{ex.class.name}: #{ex.message}"
        Dalli.logger.error ex.backtrace.join("\n\t")
        down!
      end
    end

    def alive?
      @sock && !@sock.closed?
    end

    def close
      (@sock.close rescue nil; @sock = nil) if @sock
    end

    def lock!
    end

    def unlock!
    end

    # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

    private

    def down!
      close
      @down_at = Time.now.to_i
      @msg = $!.message
      nil
    end

    ONE_MB = 1024 * 1024

    def get(key)
      req = [REQUEST, OPCODES[:get], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:get])
      write(req)
      generic_response
    end

    def getkq(key)
      req = [REQUEST, OPCODES[:getkq], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:getkq])
      write(req)
    end

    def set(key, value, ttl)
      raise Dalli::DalliError, "Value too large, memcached can only store 1MB of data per key" if value.size > ONE_MB

      req = [REQUEST, OPCODES[:set], key.size, 8, 0, 0, value.size + key.size + 8, 0, 0, 0, ttl, key, value].pack(FORMAT[:set])
      write(req)
      generic_response
    end

    def flush(ttl)
      req = [REQUEST, OPCODES[:flush], 0, 4, 0, 0, 4, 0, 0, 0].pack(FORMAT[:flush])
      write(req)
      generic_response
    end

    def add(key, value, ttl, cas)
      raise Dalli::DalliError, "Value too large, memcached can only store 1MB of data per key" if value.size > ONE_MB

      req = [REQUEST, OPCODES[:add], key.size, 8, 0, 0, value.size + key.size + 8, 0, cas, 0, ttl, key, value].pack(FORMAT[:add])
      write(req)
      generic_response
    end
    
    def append(key, value)
      req = [REQUEST, OPCODES[:append], key.size, 0, 0, 0, value.size + key.size, 0, 0, key, value].pack(FORMAT[:append])
      write(req)
      generic_response
    end
    
    def delete(key)
      req = [REQUEST, OPCODES[:delete], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:delete])
      write(req)
      generic_response
    end

    def decr(key, count, ttl, default)
      expiry = default ? ttl : 0xFFFFFFFF
      default ||= 0
      (h, l) = split(count)
      (dh, dl) = split(default)
      req = [REQUEST, OPCODES[:decr], key.size, 20, 0, 0, key.size + 20, 0, 0, h, l, dh, dl, expiry, key].pack(FORMAT[:decr])
      write(req)
      body = generic_response
      body ? longlong(*body.unpack('NN')) : body
    end
    
    def incr(key, count, ttl, default)
      expiry = default ? ttl : 0xFFFFFFFF
      default ||= 0
      (h, l) = split(count)
      (dh, dl) = split(default)
      req = [REQUEST, OPCODES[:incr], key.size, 20, 0, 0, key.size + 20, 0, 0, h, l, dh, dl, expiry, key].pack(FORMAT[:incr])
      write(req)
      body = generic_response
      body ? longlong(*body.unpack('NN')) : body
    end
    
    # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
    # We need to read all the responses at once.
    def noop
      req = [REQUEST, OPCODES[:noop], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)
      multi_response
    end

    def prepend(key, value)
      req = [REQUEST, OPCODES[:prepend], key.size, 0, 0, 0, value.size + key.size, 0, 0, key, value].pack(FORMAT[:prepend])
      write(req)
      generic_response
    end

    def replace(key, value, ttl)
      req = [REQUEST, OPCODES[:replace], key.size, 8, 0, 0, value.size + key.size + 8, 0, 0, 0, ttl, key, value].pack(FORMAT[:replace])
      write(req)
      generic_response
    end

    def version
      req = [REQUEST, OPCODES[:version], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)
      generic_response
    end

    def stats(info='')
      req = [REQUEST, OPCODES[:stat], info.size, 0, 0, 0, info.size, 0, 0, info].pack(FORMAT[:stat])
      write(req)
      keyvalue_response
    end

    def cas(key)
      req = [REQUEST, OPCODES[:get], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:get])
      write(req)
      cas_response
    end

    def cas_response
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, status, count, _, cas) = header.unpack(CAS_HEADER)
      data = read(count) if count > 0
      if status == 1
        nil
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      elsif data
        data = data[extras..-1] if extras != 0
      else
        raise Dalli::DalliError, "You're lost, how did you get here?"
      end
      [data, cas]
    end

    def generic_response
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, status, count) = header.unpack(NORMAL_HEADER)
      data = read(count) if count > 0
      if status == 1
        nil
      elsif status == 2
        false # Not stored, normal status for add operation
      elsif data
        extras != 0 ? data[extras..-1] : data
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      else
        true
      end
    end

    def keyvalue_response
      hash = {}
      loop do
        header = read(24)
        raise Dalli::NetworkError, 'No response' if !header
        (key_length, status, body_length) = header.unpack(KV_HEADER)
        return hash if key_length == 0
        key = read(key_length)
        value = read(body_length - key_length) if body_length - key_length > 0
        hash[key] = value
      end
    end

    def multi_response
      hash = {}
      loop do
        header = read(24)
        raise Dalli::NetworkError, 'No response' if !header
        (key_length, status, body_length) = header.unpack(KV_HEADER)
        return hash if key_length == 0
        read(4)
        key = read(key_length)
        value = read(body_length - key_length - 4) if body_length - key_length - 4 > 0
        hash[key] = value
      end
    end

    TIMEOUT = 0.5

    def connection
      @sock ||= begin
        if @down_at && @down_at == Time.now.to_i
          raise Dalli::NetworkError, "#{self.hostname}:#{self.port} is currently down: #{@msg}"
        end

        # All this ugly code to ensure proper Socket connect timeout
        addr = Socket.getaddrinfo(self.hostname, nil)
        sock = Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)
        begin
          sock.connect_nonblock(Socket.pack_sockaddr_in(port, addr[0][3]))
        rescue Errno::EINPROGRESS
          resp = IO.select(nil, [sock], nil, TIMEOUT)
          begin
            sock.connect_nonblock(Socket.pack_sockaddr_in(port, addr[0][3]))
          rescue Errno::EISCONN
            ;
          rescue
            raise Dalli::NetworkError, "#{self.hostname}:#{self.port} is currently down: #{$!.message}"
          end
        end
        # end ugly code

        sock.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
        sasl_authentication(sock) if Dalli::Server.need_auth?
        sock
      end
    end

    def write(bytes)
      begin
        connection.write(bytes)
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF
        down!
        raise Dalli::NetworkError, $!.class.name
      end
    end

    def read(count)
      begin
        value = ''
        begin
          loop do
            value << connection.sysread(count)
            break if value.size == count
          end
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          if IO.select([connection], nil, nil, TIMEOUT)
            retry
          else
            raise Timeout::Error, "IO timeout"
          end
        end
        value
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF, Errno::EINVAL, Timeout::Error, EOFError
        down!
        raise Dalli::NetworkError, "#{$!.class.name}: #{$!.message}"
      end
    end

    def split(n)
      [0xFFFFFFFF & n, n >> 32]
    end

    def longlong(a, b)
      a | (b << 32)
    end

    CAS_HEADER = '@4vnNNQ'
    NORMAL_HEADER = '@4vnN'
    KV_HEADER = '@2n@6nN'

    REQUEST = 0x80
    RESPONSE = 0x81
    
    RESPONSE_CODES = {
      0 => 'No error',
      1 => 'Key not found',
      2 => 'Key exists',
      3 => 'Value too large',
      4 => 'Invalid arguments',
      5 => 'Item not stored',
      6 => 'Incr/decr on a non-numeric value',
      0x20 => 'Authentication required',
      0x81 => 'Unknown command',
      0x82 => 'Out of memory',
    }
    
    OPCODES = {
      :get => 0x00,
      :set => 0x01,
      :add => 0x02,
      :replace => 0x03,
      :delete => 0x04,
      :incr => 0x05,
      :decr => 0x06,
      :flush => 0x08,
      :noop => 0x0A,
      :version => 0x0B,
      :getkq => 0x0D,
      :append => 0x0E,
      :prepend => 0x0F,
      :stat => 0x10,
      :auth_negotiation => 0x20,
      :auth_request => 0x21,
      :auth_continue => 0x22,
    }
    
    HEADER = "CCnCCnNNQ"
    OP_FORMAT = {
      :get => 'a*',
      :set => 'NNa*a*',
      :add => 'NNa*a*',
      :replace => 'NNa*a*',
      :delete => 'a*',
      :incr => 'NNNNNa*',
      :decr => 'NNNNNa*',
      :flush => 'N',
      :noop => '',
      :getkq => 'a*',
      :version => '',
      :stat => 'a*',
      :append => 'a*a*',
      :prepend => 'a*a*',
      :auth_request => 'a*a*',
      :auth_continue => 'a*a*',
    }
    FORMAT = OP_FORMAT.inject({}) { |memo, (k, v)| memo[k] = HEADER + v; memo }


    #######
    # SASL authentication support for NorthScale
    #######

    def self.need_auth?
      ENV['MEMCACHE_USERNAME']
    end
    
    def init_sasl
      require 'dalli/sasl/base'
      require 'dalli/sasl/base64'
      require 'dalli/sasl/digest_md5'
      require 'dalli/sasl/plain'
    end

    def username
      ENV['MEMCACHE_USERNAME']
    end

    def password
      ENV['MEMCACHE_PASSWORD']
    end

    def sasl_authentication(socket)
      init_sasl if !defined?(::SASL)
      
      # negotiate
      req = [REQUEST, OPCODES[:auth_negotiation], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      socket.write(req)
      header = socket.read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, status, count) = header.unpack(NORMAL_HEADER)
      raise Dalli::NetworkError, "Unexpected message format: #{extras} #{count}" unless extras == 0 && count > 0
      return (socket.read(count); Dalli.logger.debug("Authentication not required/supported by server")) if status == 0x81
      mechanisms = socket.read(count).split(' ')

      # request
      sasl = ::SASL.new(mechanisms)
      msg = sasl.start[1]
      mechanism = sasl.name
      p [mechanism, msg]
      req = [REQUEST, OPCODES[:auth_request], mechanism.size, 0, 0, 0, mechanism.size + msg.size, 0, 0, mechanism, msg].pack(FORMAT[:auth_request])
      socket.write(req)

      header = socket.read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, status, count) = header.unpack(NORMAL_HEADER)
      raise Dalli::NetworkError, "Unexpected message format: #{extras} #{count}" unless extras == 0 && count > 0
      raise Dalli::NetworkError, "Error authenticating: #{status}" unless status == 0x21
      content = socket.read(count)
      (step, msg) = sasl.receive('challenge', content)
      raise Dalli::NetworkError, "Authentication failed" if sasl.failed? || step != 'response'

      
    end
  end
end