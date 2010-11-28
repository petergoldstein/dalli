require 'socket'
require 'timeout'
require 'zlib'

module Dalli
  class Server
    attr_accessor :hostname
    attr_accessor :port
    attr_accessor :weight
    attr_accessor :options
    
    DEFAULTS = {
      # seconds between trying to contact a remote server
      :down_retry_delay => 1,
      # connect/read/write timeout for socket operations
      :socket_timeout => 0.5,
      # times a socket operation may fail before considering the server dead
      :socket_max_failures => 2,
      # amount of time to sleep between retries when a failure occurs
      :socket_failure_delay => 0.01
    }

    def initialize(attribs, options = {})
      (@hostname, @port, @weight) = attribs.split(':')
      @port ||= 11211
      @port = Integer(@port)
      @weight ||= 1
      @weight = Integer(@weight)
      @fail_count = 0
      @down_at = nil
      @last_down_at = nil
      @options = DEFAULTS.merge(options)
    end
    
    # Chokepoint method for instrumentation
    def request(op, *args)
      raise Dalli::NetworkError, "#{hostname}:#{port} is down: #{@error} #{@msg}" unless alive?
      begin
        send(op, *args)
      rescue Dalli::NetworkError
        raise
      rescue Dalli::DalliError
        raise
      rescue Exception => ex
        Dalli.logger.error "Unexpected exception in Dalli: #{ex.class.name}: #{ex.message}"
        Dalli.logger.error "This is a bug in Dalli, please enter an issue in Github if it does not already exist."
        Dalli.logger.error ex.backtrace.join("\n\t")
        down!
      end
    end

    def alive?
      return true if @sock

      if @last_down_at && @last_down_at + options[:down_retry_delay] >= Time.now
        time = @last_down_at + options[:down_retry_delay] - Time.now
        Dalli.logger.debug { "down_retry_delay not reached for #{hostname}:#{port} (%.3f seconds left)" % time }
        return false
      end

      connect
      !!@sock
    rescue Dalli::NetworkError
      false
    end

    def close
      return unless @sock
      @sock.close rescue nil
      @sock = nil
    end

    def lock!
    end

    def unlock!
    end

    # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

    private

    def failure!
      Dalli.logger.info { "#{hostname}:#{port} failed (count: #{@fail_count})" }

      @fail_count += 1
      if @fail_count >= options[:socket_max_failures]
        down!
      else
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
      end
    end
    
    def down!
      close

      @last_down_at = Time.now

      if @down_at
        time = Time.now - @down_at
        Dalli.logger.debug { "#{hostname}:#{port} is still down (for %.3f seconds now)" % time }
      else
        @down_at = @last_down_at
        Dalli.logger.warn { "#{hostname}:#{port} is down" }
      end

      @error = $! && $!.class.name
      @msg = @msg || ($! && $!.message && !$!.message.empty? && $!.message)
      raise Dalli::NetworkError, "#{hostname}:#{port} is down: #{@error} #{@msg}"
    end

    def up!
      if @down_at
        time = Time.now - @down_at
        Dalli.logger.warn { "#{hostname}:#{port} is back (downtime was %.3f seconds)" % time }
      end

      @fail_count = 0
      @down_at = nil
      @last_down_at = nil
      @msg = nil
      @error = nil
    end

    def multi?
      Thread.current[:dalli_multi]
    end

    ONE_MB = 1024 * 1024

    def get(key)
      req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
      write(req)
      generic_response(true)
    end

    def getkq(key)
      req = [REQUEST, OPCODES[:getkq], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:getkq])
      write(req)
    end

    def set(key, value, ttl, options)
      (value, flags) = serialize(value, options)

      req = [REQUEST, OPCODES[multi? ? :setq : :set], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, 0, flags, ttl, key, value].pack(FORMAT[:set])
      write(req)
      generic_response unless multi?
    end

    def add(key, value, ttl, cas, options)
      (value, flags) = serialize(value, options)

      req = [REQUEST, OPCODES[multi? ? :addq : :add], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, cas, flags, ttl, key, value].pack(FORMAT[:add])
      write(req)
      generic_response unless multi?
    end
    
    def replace(key, value, ttl, options)
      (value, flags) = serialize(value, options)
      req = [REQUEST, OPCODES[multi? ? :replaceq : :replace], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, 0, flags, ttl, key, value].pack(FORMAT[:replace])
      write(req)
      generic_response unless multi?
    end

    def delete(key)
      req = [REQUEST, OPCODES[multi? ? :deleteq : :delete], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:delete])
      write(req)
      generic_response unless multi?
    end

    def flush(ttl)
      req = [REQUEST, OPCODES[:flush], 0, 4, 0, 0, 4, 0, 0, 0].pack(FORMAT[:flush])
      write(req)
      generic_response
    end

    def decr(key, count, ttl, default)
      expiry = default ? ttl : 0xFFFFFFFF
      default ||= 0
      (h, l) = split(count)
      (dh, dl) = split(default)
      req = [REQUEST, OPCODES[:decr], key.bytesize, 20, 0, 0, key.bytesize + 20, 0, 0, h, l, dh, dl, expiry, key].pack(FORMAT[:decr])
      write(req)
      body = generic_response
      body ? longlong(*body.unpack('NN')) : body
    end
    
    def incr(key, count, ttl, default)
      expiry = default ? ttl : 0xFFFFFFFF
      default ||= 0
      (h, l) = split(count)
      (dh, dl) = split(default)
      req = [REQUEST, OPCODES[:incr], key.bytesize, 20, 0, 0, key.bytesize + 20, 0, 0, h, l, dh, dl, expiry, key].pack(FORMAT[:incr])
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

    def append(key, value)
      req = [REQUEST, OPCODES[:append], key.bytesize, 0, 0, 0, value.bytesize + key.bytesize, 0, 0, key, value].pack(FORMAT[:append])
      write(req)
      generic_response
    end

    def prepend(key, value)
      req = [REQUEST, OPCODES[:prepend], key.bytesize, 0, 0, 0, value.bytesize + key.bytesize, 0, 0, key, value].pack(FORMAT[:prepend])
      write(req)
      generic_response
    end

    def stats(info='')
      req = [REQUEST, OPCODES[:stat], info.bytesize, 0, 0, 0, info.bytesize, 0, 0, info].pack(FORMAT[:stat])
      write(req)
      keyvalue_response
    end

    def cas(key)
      req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
      write(req)
      cas_response
    end

    def version
      req = [REQUEST, OPCODES[:version], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)
      generic_response
    end

    COMPRESSION_MIN_SIZE = 1024

    # http://www.hjp.at/zettel/m/memcached_flags.rxml
    # Looks like most clients use bit 0 to indicate native language serialization
    # and bit 1 to indicate gzip compression.
    FLAG_MARSHALLED = 0x1
    FLAG_COMPRESSED = 0x2

    def serialize(value, options=nil)
      marshalled = false
      value = unless options && options[:raw]
        marshalled = true
        Marshal.dump(value)
      else
        value.to_s
      end
      compressed = false
      if @options[:compression] && value.bytesize >= COMPRESSION_MIN_SIZE
        value = Zlib::Deflate.deflate(value)
        compressed = true
      end
      raise Dalli::DalliError, "Value too large, memcached can only store 1MB of data per key" if value.bytesize > ONE_MB
      flags = 0
      flags |= FLAG_COMPRESSED if compressed
      flags |= FLAG_MARSHALLED if marshalled
      [value, flags]
    end

    def deserialize(value, flags)
      value = Zlib::Inflate.inflate(value) if (flags & FLAG_COMPRESSED) != 0
      value = Marshal.load(value) if (flags & FLAG_MARSHALLED) != 0
      value
    rescue TypeError, ArgumentError
      raise DalliError, "Unable to unmarshal value: #{$!.message}"
    rescue Zlib::Error
      raise DalliError, "Unable to uncompress value: #{$!.message}"
    end

    def cas_response
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, type, status, count, _, cas) = header.unpack(CAS_HEADER)
      data = read(count) if count > 0
      if status == 1
        nil
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      elsif data
        flags = data[0...extras].unpack('N')[0]
        value = data[extras..-1]
        data = deserialize(value, flags)
      end
      [data, cas]
    end

    CAS_HEADER = '@4CCnNNQ'
    NORMAL_HEADER = '@4CCnN'
    KV_HEADER = '@2n@6nN'

    def generic_response(unpack=false)
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, type, status, count) = header.unpack(NORMAL_HEADER)
      data = read(count) if count > 0
      if status == 1
        nil
      elsif status == 2 || status == 5
        false # Not stored, normal status for add operation
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      elsif data
        flags = data[0...extras].unpack('N')[0]
        value = data[extras..-1]
        unpack ? deserialize(value, flags) : value
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
        flags = read(4).unpack('N')[0]
        key = read(key_length)
        value = read(body_length - key_length - 4) if body_length - key_length - 4 > 0
        hash[key] = deserialize(value, flags)
      end
    end

    def write(bytes)
      begin
        @sock.write(bytes)
      rescue SystemCallError
        failure!
        retry
      end
    end

    def read(count)
      begin
        @sock.readfull(count)
      rescue SystemCallError, Timeout::Error, EOFError
        failure!
        retry
      end
    end

    def connect
      Dalli.logger.debug { "Dalli::Server#connect #{hostname}:#{port}" }

      begin
        @sock = KSocket.open(hostname, port, :timeout => options[:socket_timeout])
        @version = version # trigger actual connect
        sasl_authentication if Dalli::Server.need_auth?
        up!
      rescue Dalli::DalliError # SASL auth failure
        raise
      rescue SystemCallError, Timeout::Error, EOFError
        failure!
        retry
      end
    end

    def split(n)
      [n >> 32, 0xFFFFFFFF & n]
    end

    def longlong(a, b)
      (a << 32) | b
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
      :setq => 0x11,
      :addq => 0x12,
      :replaceq => 0x13,
      :deleteq => 0x14,
      :incrq => 0x15,
      :decrq => 0x16,
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
      require 'dalli/sasl/plain'
    end

    def username
      ENV['MEMCACHE_USERNAME']
    end

    def password
      ENV['MEMCACHE_PASSWORD']
    end

    def sasl_authentication
      init_sasl if !defined?(::SASL)

      Dalli.logger.info { "Dalli/SASL authenticating as #{username}" }

      # negotiate
      req = [REQUEST, OPCODES[:auth_negotiation], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, type, status, count) = header.unpack(NORMAL_HEADER)
      raise Dalli::NetworkError, "Unexpected message format: #{extras} #{count}" unless extras == 0 && count > 0
      content = read(count)
      return (Dalli.logger.debug("Authentication not required/supported by server")) if status == 0x81
      mechanisms = content.split(' ')

      # request
      sasl = ::SASL.new(mechanisms)
      msg = sasl.start[1]
      mechanism = sasl.name
      #p [mechanism, msg]
      req = [REQUEST, OPCODES[:auth_request], mechanism.bytesize, 0, 0, 0, mechanism.bytesize + msg.bytesize, 0, 0, mechanism, msg].pack(FORMAT[:auth_request])
      write(req)

      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, type, status, count) = header.unpack(NORMAL_HEADER)
      raise Dalli::NetworkError, "Unexpected message format: #{extras} #{count}" unless extras == 0 && count > 0
      content = read(count)
      return Dalli.logger.info("Dalli/SASL: #{content}") if status == 0

      raise Dalli::DalliError, "Error authenticating: #{status}" unless status == 0x21
      raise NotImplementedError, "No two-step authentication mechanisms supported"
      # (step, msg) = sasl.receive('challenge', content)
      # raise Dalli::NetworkError, "Authentication failed" if sasl.failed? || step != 'response'
    end
  end
end
