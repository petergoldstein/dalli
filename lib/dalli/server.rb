require 'socket'
require 'timeout'

module Dalli
  class Server
    attr_accessor :hostname
    attr_accessor :port
    attr_accessor :weight
    
    def initialize(attribs)
      (@hostname, @port, @weight) = attribs.split(':')
      @port ||= 11211
      @weight ||= 1
      connection
      Dalli.logger.debug { "#{@hostname}:#{@port} running memcached v#{request(:version)}" }
    end
    
    def request(op, *args)
      begin
        send(op, *args)
      rescue SocketError, SystemCallError, IOError, Timeout::Error
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

    private

    def down!
      close
      @down_at = Time.now
      @msg = $!.message
      nil
    end

    TIMEOUT = 0.5
    TIMEOUT_NATIVE = [0, 500_000].pack("l_2")
    ONE_MB = 1024 * 1024

    def connection
      @sock ||= begin
        begin
          s = TCPSocket.new(hostname, port)
          s.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
          begin
            s.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, TIMEOUT_NATIVE
            s.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, TIMEOUT_NATIVE
          rescue Errno::ENOPROTOOPT
          end
          s
        rescue SocketError, SystemCallError, IOError, Timeout::Error
          down!
        end
      end
    end
    
    def write(bytes)
      begin
        #Dalli.logger.debug { "[#{self.hostname}]: W #{bytes.inspect}" }
        connection.write(bytes)
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF
        raise Dalli::NetworkError, $!.class.name
      end
    end
    
    def read(count)
      begin
        value = connection.read(count)
        #Dalli.logger.debug { "[#{self.hostname}]: R #{value.inspect}" }
        value
      rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF
        raise Dalli::NetworkError, $!.class.name
      end
    end

    def get(key)
      req = [REQUEST, OPCODES[:get], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:get])
      write(req)
      generic_response
    end

    def getkq(key)
      req = [REQUEST, OPCODES[:getkq], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:getkq])
      write(req)
    end

    def set(key, value, ttl=0)
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

    def add(key, value, ttl)
      raise Dalli::DalliError, "Value too large, memcached can only store 1MB of data per key" if value.size > ONE_MB

      req = [REQUEST, OPCODES[:add], key.size, 8, 0, 0, value.size + key.size + 8, 0, 0, 0, ttl, key, value].pack(FORMAT[:add])
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
    
    def decr(key, count)
      raise NotImplementedError
    end
    
    def incr(key, count)
      raise NotImplementedError
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

    def generic_response
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, status, count) = header.unpack(NORMAL_HEADER)
      data = read(count) if count > 0
      if status == 1
        nil
      elsif status != 0
        raise Dalli::NetworkError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      elsif data
        extras != 0 ? data[extras..-1] : data
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
    }
    FORMAT = OP_FORMAT.inject({}) { |memo, (k, v)| memo[k] = HEADER + v; memo }
    
  end
end