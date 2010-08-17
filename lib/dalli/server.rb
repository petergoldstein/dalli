require 'socket'

module Dalli
  class Server
    attr_accessor :hostname
    attr_accessor :port
    attr_accessor :weight
    
    def initialize(attribs)
      (@hostname, @port, @weight) = attribs.split(':')
      @port ||= 11211
      @weight ||= 1
    end
    
    def request(op, *args)
      send(op, *args)
    end

    def alive?
      !connection.closed?
    end

    private

    def connection
      @sock ||= begin
        s = TCPSocket.new(hostname, port)
        s.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
        s
      end
    end

    def get(key)
      req = [REQUEST, OPCODES[:get], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:get])
      connection.write(req)
      generic_response
    end

    def set(key, value, ttl=0)
      req = [REQUEST, OPCODES[:set], key.size, 8, 0, 0, value.size + key.size + 8, 0, 0, 0, ttl, key, value].pack(FORMAT[:set])
      connection.write(req)
      generic_response
    end

    def flush(ttl)
      req = [REQUEST, OPCODES[:flush], 0, 4, 0, 0, 4, 0, 0, 0].pack(FORMAT[:flush])
      connection.write(req)
      generic_response
    end
    
    def add(key, value, ttl)
      req = [REQUEST, OPCODES[:add], key.size, 8, 0, 0, value.size + key.size + 8, 0, 0, 0, ttl, key, value].pack(FORMAT[:add])
      connection.write(req)
      generic_response
    end
    
    def append(key, value)
      req = [REQUEST, OPCODES[:append], key.size, 0, 0, 0, value.size + key.size, 0, 0, key, value].pack(FORMAT[:append])
      connection.write(req)
      generic_response
    end
    
    def delete(key)
      req = [REQUEST, OPCODES[:delete], key.size, 0, 0, 0, key.size, 0, 0, key].pack(FORMAT[:delete])
      connection.write(req)
      generic_response
    end
    
    def decr(key, count)
      raise NotImplementedError
    end
    
    def incr(key, count)
      raise NotImplementedError
    end
    
    def noop
      req = [REQUEST, OPCODES[:noop], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      connection.write(req)
      generic_response
    end
    
    def prepend(key, value)
      req = [REQUEST, OPCODES[:prepend], key.size, 0, 0, 0, value.size + key.size, 0, 0, key, value].pack(FORMAT[:prepend])
      connection.write(req)
      generic_response
    end
    
    def replace(key, value, ttl)
      req = [REQUEST, OPCODES[:replace], key.size, 8, 0, 0, value.size + key.size + 8, 0, 0, 0, ttl, key, value].pack(FORMAT[:replace])
      connection.write(req)
      generic_response
    end

    def generic_response
      header = connection.read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, status, count) = header.unpack('@4vnN')
      data = connection.read(count) if count > 0
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
      :version => '',
      :stat => 'a*',
      :append => 'a*a*',
      :prepend => 'a*a*',
    }
    FORMAT = OP_FORMAT.inject({}) { |memo, (k, v)| memo[k] = HEADER + v; memo }
    
    TYPES = {
      :raw => 0
    }
    

  end
end