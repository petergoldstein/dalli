require 'socket'

module Dalli
  class Server
    attr_accessor :hostname
    attr_accessor :port
    attr_accessor :weight
    
    def initialize(attribs)
      (@hostname, @port, @weight) = attribs.split(':')
    end
    
    def send_request(req)
      puts req
      connection.write(req)
    end
    
    def read_response
      line = connection.gets
      return nil if line == "END\r\n"
      return line if line == "STORED\r\n"
      raise Dalli::NetworkError, "Error: '#{$1}'" if line =~ /ERROR(.*)\r\n/

      unless line =~ /(\d+)\r/
        raise Dalli::NetworkError, "Unexpected response: '#{line}'"
      end

      count = $1.to_i
      value = connection.read(count)
      connection.read(2)
      connection.gets
      value
    end
    
    def connection
      @sock ||= begin
        s = TCPSocket.new(hostname, port)
        s.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
        s
      end
    end

    def request(op, *args)
      send(op, *args)
    end
    
    def get(key)
      req = [REQUEST, OPCODES[:get],key.size,0,0,0,key.size,0,0,key].pack(FORMAT[:get])
      connection.write(req)
      generic_response
    end
    
    def set(key, value, ttl=0)
      req = [REQUEST, OPCODES[:set], key.size,8,0,0,value.size + key.size + 8,0,0,0,ttl, key, value].pack(FORMAT[:set])
      connection.write(req)
      generic_response
    end
    
    def generic_response
      header = connection.read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (status, count) = header.unpack('@6nN')
      if count > 0
        connection.read(count)
      elsif status != 0
        raise Dalli::NetworkError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      else
        true
      end
    end

    def get(key)
      [REQUEST, OPCODES[:get], key.size, 0,0,0,key.size,0,0,key].pack(FORMAT[:get])
    end

    private
    
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
      :increment => 0x05,
      :decrement => 0x06,
      :flush => 0x08,
      :noop => 0x0A,
      :version => 0x0B,
      :stat => 0x0C,
    }
    
    HEADER = "CCnCCnNNQ"
    OP_FORMAT = {
      :get => 'a*',
      :set => 'NNa*a*',
      :add => 'NNa*a*',
      :replace => 'NNa*a*',
      :delete => 'a*',
      :increment => 'NNNNNa*',
      :decrement => 'NNNNNa*',
      :flush => 'N',
      :noop => '',
      :version => '',
      :stat => 'a*'
    }
    FORMAT = OP_FORMAT.inject({}) { |memo, (k, v)| memo[k] = HEADER + v; memo }
    
    TYPES = {
      :raw => 0
    }
    

  end
end