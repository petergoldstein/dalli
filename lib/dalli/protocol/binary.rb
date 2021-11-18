# frozen_string_literal: true

require 'English'
require 'forwardable'
require 'socket'
require 'timeout'

module Dalli
  module Protocol
    ##
    # Access point for a single Memcached server, accessed via Memcached's binary
    # protocol.  Contains logic for managing connection state to the server (retries, etc),
    # formatting requests to the server, and unpacking responses.
    ##
    class Binary
      extend Forwardable

      attr_accessor :hostname, :port, :weight, :options
      attr_reader :sock, :socket_type

      def_delegators :@value_marshaller, :serializer, :compressor, :compression_min_size, :compress_by_default?

      DEFAULTS = {
        # seconds between trying to contact a remote server
        down_retry_delay: 30,
        # connect/read/write timeout for socket operations
        socket_timeout: 1,
        # times a socket operation may fail before considering the server dead
        socket_max_failures: 2,
        # amount of time to sleep between retries when a failure occurs
        socket_failure_delay: 0.1,
        # max size of value in bytes (default is 1 MB, can be overriden with "memcached -I <size>")
        value_max_bytes: 1024 * 1024,
        username: nil,
        password: nil,
        keepalive: true,
        # max byte size for SO_SNDBUF
        sndbuf: nil,
        # max byte size for SO_RCVBUF
        rcvbuf: nil
      }.freeze

      def initialize(attribs, options = {})
        @hostname, @port, @weight, @socket_type, options = ServerConfigParser.parse(attribs, options)
        @options = DEFAULTS.merge(options)
        @value_marshaller = ValueMarshaller.new(@options)

        reset_down_info

        @sock = nil
        @pid = nil
        @request_in_progress = false
      end

      def name
        if socket_type == :unix
          hostname
        else
          "#{hostname}:#{port}"
        end
      end

      # Chokepoint method for instrumentation
      def request(opcode, *args)
        verify_state
        unless alive?
          raise Dalli::NetworkError,
                "#{name} is down: #{@error} #{@msg}. If you are sure it is running, ensure memcached version is > 1.4."
        end

        begin
          send(opcode, *args)
        rescue Dalli::MarshalError => e
          Dalli.logger.error "Marshalling error for key '#{args.first}': #{e.message}"
          Dalli.logger.error 'You are trying to cache a Ruby object which cannot be serialized to memcached.'
          raise
        rescue Dalli::DalliError, Dalli::NetworkError, Dalli::ValueOverMaxSize, Timeout::Error
          raise
        rescue StandardError => e
          Dalli.logger.error "Unexpected exception during Dalli request: #{e.class.name}: #{e.message}"
          Dalli.logger.error e.backtrace.join("\n\t")
          down!
        end
      end

      def alive?
        return true if @sock
        return false unless reconnect_down_server?

        connect
        !!@sock
      rescue Dalli::NetworkError
        false
      end

      def reconnect_down_server?
        return true unless @last_down_at

        time_to_next_reconnect = @last_down_at + options[:down_retry_delay] - Time.now
        return true unless time_to_next_reconnect.positive?

        Dalli.logger.debug do
          format('down_retry_delay not reached for %<name>s (%<time>.3f seconds left)', name: name,
                                                                                        time: time_to_next_reconnect)
        end
        false
      end

      def close
        return unless @sock

        begin
          @sock.close
        rescue StandardError
          nil
        end
        @sock = nil
        @pid = nil
        abort_request!
      end

      def lock!; end

      def unlock!; end

      # Start reading key/value pairs from this connection. This is usually called
      # after a series of GETKQ commands. A NOOP is sent, and the server begins
      # flushing responses for kv pairs that were found.
      #
      # Returns nothing.
      def multi_response_start
        verify_state
        write_noop
        @multi_buffer = +''
        @position = 0
        start_request!
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
        reconnect! 'multi_response has completed' if @multi_buffer.nil?

        @multi_buffer << @sock.read_available
        buf = @multi_buffer
        pos = @position
        values = {}

        while buf.bytesize - pos >= HEADER_SIZE
          _, extra_len, key_len, body_len, cas = unpack_header(buf.slice(pos, HEADER_SIZE))

          # We've reached the noop at the end of the pipeline
          if key_len.zero?
            finish_multi_response
            break
          end

          # Break and read more unless we already have the entire response for this header
          break unless buf.bytesize - pos >= HEADER_SIZE + body_len

          body = buf.slice(pos + HEADER_SIZE, body_len)
          begin
            key, value = unpack_response_body(extra_len, key_len, body, true)
            values[key] = [value, cas]
          rescue DalliError
            # TODO: Determine if we should be swallowing
            # this error
          end

          pos = pos + HEADER_SIZE + body_len
        end
        # TODO: We should be discarding the already processed buffer at this point
        @position = pos

        values
      rescue SystemCallError, Timeout::Error, EOFError => e
        failure!(e)
      end

      def finish_multi_response
        @multi_buffer = nil
        @position = nil
        finish_request!
      end

      # Abort an earlier #multi_response_start. Used to signal an external
      # timeout. The underlying socket is disconnected, and the exception is
      # swallowed.
      #
      # Returns nothing.
      def multi_response_abort
        @multi_buffer = nil
        @position = nil
        abort_request!
        failure!(RuntimeError.new('External timeout'))
      rescue NetworkError
        true
      end

      # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

      private

      def request_in_progress?
        @request_in_progress
      end

      def start_request!
        @request_in_progress = true
      end

      def finish_request!
        @request_in_progress = false
      end

      def abort_request!
        @request_in_progress = false
      end

      def verify_state
        failure!(RuntimeError.new('Already writing to socket')) if request_in_progress?
        reconnect_on_fork if fork_detected?
      end

      def fork_detected?
        @pid && @pid != Process.pid
      end

      def reconnect_on_fork
        message = 'Fork detected, re-connecting child process...'
        Dalli.logger.info { message }
        reconnect! message
      end

      def reconnect!(message)
        close
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
        raise Dalli::NetworkError, message
      end

      def failure!(exception)
        message = "#{name} failed (count: #{@fail_count}) #{exception.class}: #{exception.message}"
        Dalli.logger.warn { message }

        @fail_count += 1
        if @fail_count >= options[:socket_max_failures]
          down!
        else
          reconnect! 'Socket operation failed, retrying...'
        end
      end

      def down!
        close
        log_down_detected

        @error = $ERROR_INFO&.class&.name
        @msg ||= $ERROR_INFO&.message
        raise Dalli::NetworkError, "#{name} is down: #{@error} #{@msg}"
      end

      def log_down_detected
        @last_down_at = Time.now

        if @down_at
          time = Time.now - @down_at
          Dalli.logger.debug { format('%<name>s is still down (for %<time>.3f seconds now)', name: name, time: time) }
        else
          @down_at = @last_down_at
          Dalli.logger.warn("#{name} is down")
        end
      end

      def log_up_detected
        return unless @down_at

        time = Time.now - @down_at
        Dalli.logger.warn { format('%<name>s is back (downtime was %<time>.3f seconds)', name: name, time: time) }
      end

      def up!
        log_up_detected
        reset_down_info
      end

      def reset_down_info
        @fail_count = 0
        @down_at = nil
        @last_down_at = nil
        @msg = nil
        @error = nil
      end

      def multi?
        Thread.current[:dalli_multi]
      end

      def get(key, options = nil)
        req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
        write(req)
        generic_response(unpack: true, cache_nils: !!(options && options.is_a?(Hash) && options[:cache_nils]))
      end

      def send_multiget(keys)
        req = +''
        keys.each do |key|
          req << [REQUEST, OPCODES[:getkq], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:getkq])
        end
        # Could send noop here instead of in multi_response_start
        write(req)
      end

      def set(key, value, ttl, cas, options)
        (value, flags) = @value_marshaller.store(key, value, options)
        ttl = TtlSanitizer.sanitize(ttl)

        req = [REQUEST, OPCODES[multi? ? :setq : :set], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0,
               cas, flags, ttl, key, value].pack(FORMAT[:set])
        write(req)
        cas_response unless multi?
      end

      def add(key, value, ttl, options)
        (value, flags) = @value_marshaller.store(key, value, options)
        ttl = TtlSanitizer.sanitize(ttl)

        req = [REQUEST, OPCODES[multi? ? :addq : :add], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, 0,
               flags, ttl, key, value].pack(FORMAT[:add])
        write(req)
        cas_response unless multi?
      end

      def replace(key, value, ttl, cas, options)
        (value, flags) = @value_marshaller.store(key, value, options)
        ttl = TtlSanitizer.sanitize(ttl)

        req = [REQUEST, OPCODES[multi? ? :replaceq : :replace], key.bytesize, 8, 0, 0,
               value.bytesize + key.bytesize + 8, 0, cas, flags, ttl, key, value].pack(FORMAT[:replace])
        write(req)
        cas_response unless multi?
      end

      def delete(key, cas)
        req = [REQUEST, OPCODES[multi? ? :deleteq : :delete], key.bytesize, 0, 0, 0, key.bytesize, 0, cas,
               key].pack(FORMAT[:delete])
        write(req)
        generic_response unless multi?
      end

      def flush(_ttl)
        req = [REQUEST, OPCODES[:flush], 0, 4, 0, 0, 4, 0, 0, 0].pack(FORMAT[:flush])
        write(req)
        generic_response
      end

      def decr_incr(opcode, key, count, ttl, default)
        expiry = default ? TtlSanitizer.sanitize(ttl) : 0xFFFFFFFF
        default ||= 0
        (h, l) = split(count)
        (dh, dl) = split(default)
        req = [REQUEST, OPCODES[opcode], key.bytesize, 20, 0, 0, key.bytesize + 20, 0, 0, h, l, dh, dl, expiry,
               key].pack(FORMAT[opcode])
        write(req)
        decr_incr_response
      end

      def split(quadword)
        [quadword >> 32, 0xFFFFFFFF & quadword]
      end

      def decr(key, count, ttl, default)
        decr_incr :decr, key, count, ttl, default
      end

      def incr(key, count, ttl, default)
        decr_incr :incr, key, count, ttl, default
      end

      def write_append_prepend(opcode, key, value)
        write_generic [REQUEST, OPCODES[opcode], key.bytesize, 0, 0, 0, value.bytesize + key.bytesize, 0, 0, key,
                       value].pack(FORMAT[opcode])
      end

      def write_generic(bytes)
        write(bytes)
        generic_response
      end

      def write_noop
        req = [REQUEST, OPCODES[:noop], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
        write(req)
      end

      # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
      # We need to read all the responses at once.
      def noop
        write_noop
        multi_with_keys_response
      end

      def append(key, value)
        write_append_prepend :append, key, value
      end

      def prepend(key, value)
        write_append_prepend :prepend, key, value
      end

      def stats(info = '')
        req = [REQUEST, OPCODES[:stat], info.bytesize, 0, 0, 0, info.bytesize, 0, 0, info].pack(FORMAT[:stat])
        write(req)
        multi_with_keys_response
      end

      def reset_stats
        write_generic [REQUEST, OPCODES[:stat], 'reset'.bytesize, 0, 0, 0, 'reset'.bytesize, 0, 0,
                       'reset'].pack(FORMAT[:stat])
      end

      def cas(key)
        req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
        write(req)
        data_cas_response
      end

      def version
        write_generic [REQUEST, OPCODES[:version], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      end

      def touch(key, ttl)
        ttl = TtlSanitizer.sanitize(ttl)
        write_generic [REQUEST, OPCODES[:touch], key.bytesize, 4, 0, 0, key.bytesize + 4, 0, 0, ttl,
                       key].pack(FORMAT[:touch])
      end

      def gat(key, ttl, options = nil)
        ttl = TtlSanitizer.sanitize(ttl)
        req = [REQUEST, OPCODES[:gat], key.bytesize, 4, 0, 0, key.bytesize + 4, 0, 0, ttl, key].pack(FORMAT[:gat])
        write(req)
        generic_response(unpack: true, cache_nils: !!(options && options.is_a?(Hash) && options[:cache_nils]))
      end

      def connect
        Dalli.logger.debug { "Dalli::Server#connect #{name}" }

        begin
          @pid = Process.pid
          @sock = if socket_type == :unix
                    Dalli::Socket::UNIX.open(hostname, self, options)
                  else
                    Dalli::Socket::TCP.open(hostname, port, self, options)
                  end
          sasl_authentication if need_auth?
          @version = version # trigger actual connect
          up!
        rescue Dalli::DalliError # SASL auth failure
          raise
        rescue SystemCallError, Timeout::Error, EOFError, SocketError => e
          # SocketError = DNS resolution failure
          failure!(e)
        end
      end

      NORMAL_HEADER = '@2nCCnNNQ'
      HEADER_SIZE = 24

      # Response codes taken from:
      # https://github.com/memcached/memcached/wiki/BinaryProtocolRevamped#response-status
      RESPONSE_CODES = {
        0 => 'No error',
        1 => 'Key not found',
        2 => 'Key exists',
        3 => 'Value too large',
        4 => 'Invalid arguments',
        5 => 'Item not stored',
        6 => 'Incr/decr on a non-numeric value',
        7 => 'The vbucket belongs to another server',
        8 => 'Authentication error',
        9 => 'Authentication continue',
        0x20 => 'Authentication required',
        0x81 => 'Unknown command',
        0x82 => 'Out of memory',
        0x83 => 'Not supported',
        0x84 => 'Internal error',
        0x85 => 'Busy',
        0x86 => 'Temporary failure'
      }.freeze

      def read(count)
        start_request!
        data = @sock.readfull(count)
        finish_request!
        data
      rescue SystemCallError, Timeout::Error, EOFError => e
        failure!(e)
      end

      def read_header
        read(HEADER_SIZE) || raise(Dalli::NetworkError, 'No response')
      end

      def generic_response(unpack: false, cache_nils: false)
        status, extra_len, body, _, key_len = read_response

        return cache_nils ? ::Dalli::NOT_FOUND : nil if status == 1
        return false if [2, 5].include?(status) # Not stored, normal status for add operation
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}" if status != 0
        return true unless body

        unpack_response_body(extra_len, key_len, body, unpack).last
      end

      def read_response
        status, extra_len, key_len, body_len, cas = unpack_header(read_header)
        body = read(body_len) if body_len.positive?
        [status, extra_len, body, cas, key_len]
      end

      def unpack_header(header)
        (key_len, extra_len, _, status, body_len, _, cas) = header.unpack(NORMAL_HEADER)
        [status, extra_len, key_len, body_len, cas]
      end

      def unpack_response_body(extra_len, key_len, body, unpack)
        bitflags = body.byteslice(0, extra_len).unpack1('N') if extra_len.positive?
        key = body.byteslice(extra_len, key_len) if key_len.positive?
        value = body.byteslice(extra_len + key_len, body.bytesize - extra_len)
        value = unpack ? @value_marshaller.retrieve(value, bitflags) : value
        [key, value]
      end

      def data_cas_response
        status, extra_len, body, cas, key_len = read_response
        return [nil, cas] if status == 1
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}" if status != 0
        return [nil, cas] unless body # This should never happen, becuase a valid get should always return a body

        [unpack_response_body(extra_len, key_len, body, true).last, cas]
      end

      def cas_response
        status, _, _, cas, = read_response
        return nil if status == 1
        return false if [2, 5].include?(status)
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}" if status != 0

        cas
      end

      def multi_with_keys_response
        hash = {}
        loop do
          _, extra_len, body, _, key_len = read_response
          return hash if key_len.zero?

          body_len = body.bytesize
          bitflags = extra_len.positive? ? body.byteslice(0, extra_len) : 0x0
          key = body.byteslice(extra_len, key_len)
          value_len = body_len - key_len - extra_len
          value = body.byteslice(extra_len + key_len, value_len)
          hash[key] = @value_marshaller.retrieve(value, bitflags)
        end
      end

      def decr_incr_response
        body = generic_response
        body ? body.unpack1('Q>') : body
      end

      def validate_auth_format(extra_len, count)
        return if extra_len.zero? && count.positive?

        raise Dalli::NetworkError, "Unexpected message format: #{extra_len} #{count}"
      end

      def auth_response
        (extra_len, _type, status, count) = read_header.unpack(NORMAL_HEADER)
        validate_auth_format(extra_len, count)
        content = read(count)
        [status, content]
      end

      def write(bytes)
        start_request!
        result = @sock.write(bytes)
        finish_request!
        result
      rescue SystemCallError, Timeout::Error => e
        failure!(e)
      end

      REQUEST = 0x80
      RESPONSE = 0x81

      OPCODES = {
        get: 0x00,
        set: 0x01,
        add: 0x02,
        replace: 0x03,
        delete: 0x04,
        incr: 0x05,
        decr: 0x06,
        flush: 0x08,
        noop: 0x0A,
        version: 0x0B,
        getkq: 0x0D,
        append: 0x0E,
        prepend: 0x0F,
        stat: 0x10,
        setq: 0x11,
        addq: 0x12,
        replaceq: 0x13,
        deleteq: 0x14,
        incrq: 0x15,
        decrq: 0x16,
        auth_negotiation: 0x20,
        auth_request: 0x21,
        auth_continue: 0x22,
        touch: 0x1C,
        gat: 0x1D
      }.freeze

      HEADER = 'CCnCCnNNQ'
      OP_FORMAT = {
        get: 'a*',
        set: 'NNa*a*',
        add: 'NNa*a*',
        replace: 'NNa*a*',
        delete: 'a*',
        incr: 'NNNNNa*',
        decr: 'NNNNNa*',
        flush: 'N',
        noop: '',
        getkq: 'a*',
        version: '',
        stat: 'a*',
        append: 'a*a*',
        prepend: 'a*a*',
        auth_request: 'a*a*',
        auth_continue: 'a*a*',
        touch: 'Na*',
        gat: 'Na*'
      }.freeze
      FORMAT = OP_FORMAT.transform_values { |v| HEADER + v; }

      #######
      # SASL authentication support for NorthScale
      #######

      def need_auth?
        !username.nil?
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

        status, content = auth_response
        # TODO: Determine if this substitution is needed
        content.tr("\u0000", ' ')
        return Dalli.logger.debug('Authentication not required/supported by server') if status == 0x81

        mechanisms = content.split
        unless mechanisms.include?('PLAIN')
          raise NotImplementedError,
                'Dalli only supports the PLAIN authentication mechanism'
        end

        # request
        mechanism = 'PLAIN'
        msg = "\x0#{username}\x0#{password}"
        req = [REQUEST, OPCODES[:auth_request], mechanism.bytesize, 0, 0, 0, mechanism.bytesize + msg.bytesize, 0, 0,
               mechanism, msg].pack(FORMAT[:auth_request])
        write(req)

        status, content = auth_response
        return Dalli.logger.info("Dalli/SASL: #{content}") if status.zero?

        raise Dalli::DalliError, "Error authenticating: #{status}" unless status == 0x21

        raise NotImplementedError, 'No two-step authentication mechanisms supported'
        # (step, msg) = sasl.receive('challenge', content)
        # raise Dalli::NetworkError, "Authentication failed" if sasl.failed? || step != 'response'
      end
    end
  end
end
