require 'socket'
require 'timeout'

module Dalli
  class Server
    attr_accessor :hostname
    attr_accessor :port
    attr_accessor :weight
    attr_accessor :options
    attr_reader :sock

    DEFAULTS = {
      # seconds between trying to contact a remote server
      :down_retry_delay => 1,
      # connect/read/write timeout for socket operations
      :socket_timeout => 0.5,
      # times a socket operation may fail before considering the server dead
      :socket_max_failures => 2,
      # amount of time to sleep between retries when a failure occurs
      :socket_failure_delay => 0.01,
      # max size of value in bytes (default is 1 MB, can be overriden with "memcached -I <size>")
      :value_max_bytes => 1024 * 1024,
      :compressor => Compressor,
      # min byte size to attempt compression
      :compression_min_size => 1024,
      # max byte size for compression
      :compression_max_size => false,
      :serializer => Marshal,
      :username => nil,
      :password => nil,
      :keepalive => true
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
      @sock = nil
      @msg = nil
      @pid = nil
      @inprogress = nil
    end

    # Chokepoint method for instrumentation
    def request(op, *args)
      verify_state
      raise Dalli::NetworkError, "#{hostname}:#{port} is down: #{@error} #{@msg}" unless alive?
      begin
        send(op, *args)
      rescue Dalli::NetworkError
        raise
      rescue Dalli::MarshalError => ex
        Dalli.logger.error "Marshalling error for key '#{args.first}': #{ex.message}"
        Dalli.logger.error "You are trying to cache a Ruby object which cannot be serialized to memcached."
        Dalli.logger.error ex.backtrace.join("\n\t")
        false
      rescue Dalli::DalliError
        raise
      rescue => ex
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
      @pid = nil
      @inprogress = false
    end

    def lock!
    end

    def unlock!
    end

    def serializer
      @options[:serializer]
    end

    def compressor
      @options[:compressor]
    end

    # Start reading key/value pairs from this connection. This is usually called
    # after a series of GETKQ commands. A NOOP is sent, and the server begins
    # flushing responses for kv pairs that were found.
    #
    # Returns nothing.
    def multi_response_start
      verify_state
      write_noop
      @multi_buffer = ''
      @position = 0
      @inprogress = true
    end

    # Did the last call to #multi_response_start complete successfully?
    def multi_response_completed?
      @multi_buffer.nil?
    end

    # Attempt to receive and parse as many key/value pairs as possible
    # from this server. After #multi_response_start, this should be invoked
    # repeatedly whenever this server's socket is readable until
    # #multi_response_completed?.
    #
    # Returns a Hash of kv pairs received.
    def multi_response_nonblock
      raise 'multi_response has completed' if @multi_buffer.nil?

      @multi_buffer << @sock.read_available
      buf = @multi_buffer
      pos = @position
      values = {}

      while buf.bytesize - pos >= 24
        header = buf.slice(pos, 24)
        (key_length, _, body_length) = header.unpack(KV_HEADER)

        if key_length == 0
          # all done!
          @multi_buffer = nil
          @position = nil
          @inprogress = false
          break

        elsif buf.bytesize - pos >= 24 + body_length
          flags = buf.slice(pos + 24, 4).unpack('N')[0]
          key = buf.slice(pos + 24 + 4, key_length)
          value = buf.slice(pos + 24 + 4 + key_length, body_length - key_length - 4) if body_length - key_length - 4 > 0

          pos = pos + 24 + body_length

          begin
            values[key] = deserialize(value, flags)
          rescue DalliError
          end

        else
          # not enough data yet, wait for more
          break
        end
      end
      @position = pos

      values
    rescue SystemCallError, Timeout::Error, EOFError
      failure!
    end

    # Abort an earlier #multi_response_start. Used to signal an external
    # timeout. The underlying socket is disconnected, and the exception is
    # swallowed.
    #
    # Returns nothing.
    def multi_response_abort
      @multi_buffer = nil
      @position = nil
      @inprogress = false
      failure!
    rescue NetworkError
      true
    end

    # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

    private

    def verify_state
      failure! if @inprogress
      failure! if @pid && @pid != Process.pid
    end

    def failure!
      Dalli.logger.info { "#{hostname}:#{port} failed (count: #{@fail_count})" }

      @fail_count += 1
      if @fail_count >= options[:socket_max_failures]
        down!
      else
        close
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
        raise Dalli::NetworkError, "Socket operation failed, retrying..."
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

    def get(key)
      req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
      write(req)
      generic_response(true)
    end

    def send_multiget(keys)
      req = ""
      keys.each do |key|
        req << [REQUEST, OPCODES[:getkq], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:getkq])
      end
      # Could send noop here instead of in multi_response_start
      write(req)
    end

    def set(key, value, ttl, cas, options)
      (value, flags) = serialize(key, value, options)

      if under_max_value_size?(value)
        req = [REQUEST, OPCODES[multi? ? :setq : :set], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, cas, flags, ttl, key, value].pack(FORMAT[:set])
        write(req)
        generic_response unless multi?
      else
        false
      end
    end

    def add(key, value, ttl, options)
      (value, flags) = serialize(key, value, options)

      if under_max_value_size?(value)
        req = [REQUEST, OPCODES[multi? ? :addq : :add], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, 0, flags, ttl, key, value].pack(FORMAT[:add])
        write(req)
        generic_response unless multi?
      else
        false
      end
    end

    def replace(key, value, ttl, options)
      (value, flags) = serialize(key, value, options)

      if under_max_value_size?(value)
        req = [REQUEST, OPCODES[multi? ? :replaceq : :replace], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, 0, flags, ttl, key, value].pack(FORMAT[:replace])
        write(req)
        generic_response unless multi?
      else
        false
      end
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

    def write_noop
      req = [REQUEST, OPCODES[:noop], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)
    end

    # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
    # We need to read all the responses at once.
    def noop
      write_noop
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

    def reset_stats
      req = [REQUEST, OPCODES[:stat], 'reset'.bytesize, 0, 0, 0, 'reset'.bytesize, 0, 0, 'reset'].pack(FORMAT[:stat])
      write(req)
      generic_response
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

    def touch(key, ttl)
      req = [REQUEST, OPCODES[:touch], key.bytesize, 4, 0, 0, key.bytesize + 4, 0, 0, ttl, key].pack(FORMAT[:touch])
      write(req)
      generic_response
    end

    # http://www.hjp.at/zettel/m/memcached_flags.rxml
    # Looks like most clients use bit 0 to indicate native language serialization
    # and bit 1 to indicate gzip compression.
    FLAG_SERIALIZED = 0x1
    FLAG_COMPRESSED = 0x2

    def serialize(key, value, options=nil)
      marshalled = false
      value = unless options && options[:raw]
        marshalled = true
        begin
          self.serializer.dump(value)
        rescue => ex
          # Marshalling can throw several different types of generic Ruby exceptions.
          # Convert to a specific exception so we can special case it higher up the stack.
          exc = Dalli::MarshalError.new(ex.message)
          exc.set_backtrace ex.backtrace
          raise exc
        end
      else
        value.to_s
      end
      compressed = false
      if @options[:compress] && value.bytesize >= @options[:compression_min_size] &&
        (!@options[:compression_max_size] || value.bytesize <= @options[:compression_max_size])
        value = self.compressor.compress(value)
        compressed = true
      end

      flags = 0
      flags |= FLAG_COMPRESSED if compressed
      flags |= FLAG_SERIALIZED if marshalled
      [value, flags]
    end

    def deserialize(value, flags)
      value = self.compressor.decompress(value) if (flags & FLAG_COMPRESSED) != 0
      value = self.serializer.load(value) if (flags & FLAG_SERIALIZED) != 0
      value
    rescue TypeError
      raise if $!.message !~ /needs to have method `_load'|exception class\/object expected|instance of IO needed|incompatible marshal file format/
      raise UnmarshalError, "Unable to unmarshal value: #{$!.message}"
    rescue ArgumentError
      raise if $!.message !~ /undefined class|marshal data too short/
      raise UnmarshalError, "Unable to unmarshal value: #{$!.message}"
    rescue Zlib::Error
      raise UnmarshalError, "Unable to uncompress value: #{$!.message}"
    end

    def cas_response
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, _, status, count, _, cas) = header.unpack(CAS_HEADER)
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

    def under_max_value_size?(value)
      value.bytesize <= @options[:value_max_bytes]
    end

    def generic_response(unpack=false)
      header = read(24)
      raise Dalli::NetworkError, 'No response' if !header
      (extras, _, status, count) = header.unpack(NORMAL_HEADER)
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
        (key_length, _, body_length) = header.unpack(KV_HEADER)
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
        (key_length, _, body_length) = header.unpack(KV_HEADER)
        return hash if key_length == 0
        flags = read(4).unpack('N')[0]
        key = read(key_length)
        value = read(body_length - key_length - 4) if body_length - key_length - 4 > 0
        hash[key] = deserialize(value, flags)
      end
    end

    def write(bytes)
      begin
        @inprogress = true
        result = @sock.write(bytes)
        @inprogress = false
        result
      rescue SystemCallError, Timeout::Error
        failure!
      end
    end

    def read(count)
      begin
        @inprogress = true
        data = @sock.readfull(count)
        @inprogress = false
        data
      rescue SystemCallError, Timeout::Error, EOFError
        failure!
      end
    end

    def connect
      Dalli.logger.debug { "Dalli::Server#connect #{hostname}:#{port}" }

      begin
        @pid = Process.pid
        @sock = KSocket.open(hostname, port, self, options)
        @version = version # trigger actual connect
        sasl_authentication if need_auth?
        up!
      rescue Dalli::DalliError # SASL auth failure
        raise
      rescue SystemCallError, Timeout::Error, EOFError, SocketError
        # SocketError = DNS resolution failure
        failure!
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
      :touch => 0x1C,
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
      :touch => 'Na*',
    }
    FORMAT = OP_FORMAT.inject({}) { |memo, (k, v)| memo[k] = HEADER + v; memo }


    #######
    # SASL authentication support for NorthScale
    #######

    def need_auth?
      @options[:username] || ENV['MEMCACHE_USERNAME']
    end

    def username
      @options[:username] || ENV['MEMCACHE_USERNAME']
    end

    def password
      @options[:password] || ENV['MEMCACHE_PASSWORD']
    end

    def sasl_authentication
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
      raise NotImplementedError, "Dalli only supports the PLAIN authentication mechanism" if !mechanisms.include?('PLAIN')

      # request
      mechanism = 'PLAIN'
      msg = "\x0#{username}\x0#{password}"
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
