# frozen_string_literal: true

require 'English'
require 'forwardable'
require 'socket'
require 'timeout'

require_relative 'binary/request_formatter'
require_relative 'binary/response_header'
require_relative 'binary/response_processor'
require_relative 'binary/sasl_authentication'

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
        socket_failure_delay: 0.1
      }.freeze

      def initialize(attribs, options = {})
        @hostname, @port, @weight, @socket_type, options = ServerConfigParser.parse(attribs, options)
        @options = DEFAULTS.merge(options)
        @value_marshaller = ValueMarshaller.new(@options)
        @response_processor = ResponseProcessor.new(self, @value_marshaller)
        @response_buffer = ResponseBuffer.new(self, @response_processor)

        reset_down_info
        @sock = nil
        @pid = nil
        @request_in_progress = false
      end

      def response_buffer
        @response_buffer ||= ResponseBuffer.new(self, @response_processor)
      end

      def name
        if socket_type == :unix
          hostname
        else
          "#{hostname}:#{port}"
        end
      end

      # Chokepoint method for error handling and ensuring liveness
      def request(opkey, *args)
        verify_state(opkey)
        # The alive? call has the side effect of connecting the underlying
        # socket if it is not connected, or there's been a disconnect
        # because of timeout or other error.  Method raises an error
        # if it can't connect
        raise_memcached_down_err unless alive?

        begin
          send(opkey, *args)
        rescue Dalli::MarshalError => e
          log_marshall_err(args.first, e)
          raise
        rescue Dalli::DalliError, Dalli::NetworkError, Dalli::ValueOverMaxSize, Timeout::Error
          raise
        rescue StandardError => e
          log_unexpected_err(e)
          down!
        end
      end

      def raise_memcached_down_err
        raise Dalli::NetworkError,
              "#{name} is down: #{@error} #{@msg}. If you are sure it is running, "\
              "ensure memcached version is > #{::Dalli::MIN_SUPPORTED_MEMCACHED_VERSION}."
      end

      def log_marshall_err(key, err)
        Dalli.logger.error "Marshalling error for key '#{key}': #{err.message}"
        Dalli.logger.error 'You are trying to cache a Ruby object which cannot be serialized to memcached.'
      end

      def log_unexpected_err(err)
        Dalli.logger.error "Unexpected exception during Dalli request: #{err.class.name}: #{err.message}"
        Dalli.logger.error err.backtrace.join("\n\t")
      end

      # The socket connection to the underlying server is initialized as a side
      # effect of this call.  In fact, this is the ONLY place where that
      # socket connection is initialized.
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

      # Closes the underlying socket and cleans up
      # socket state.
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
      def pipeline_response_start
        verify_state(:getkq)
        write_noop
        response_buffer.reset
        start_request!
      end

      # Did the last call to #pipeline_response_start complete successfully?
      def pipeline_response_completed?
        response_buffer.completed?
      end

      def pipeline_response(bytes_to_advance = 0)
        response_buffer.process_single_response(bytes_to_advance)
      end

      def reconnect_on_pipeline_complete!
        reconnect! 'multi_response has completed' if pipeline_response_completed?
      end

      # Attempt to receive and parse as many key/value pairs as possible
      # from this server. After #pipeline_response_start, this should be invoked
      # repeatedly whenever this server's socket is readable until
      # #pipeline_response_completed?.
      #
      # Returns a Hash of kv pairs received.
      def process_outstanding_pipeline_requests
        reconnect_on_pipeline_complete!
        values = {}

        response_buffer.read

        bytes_to_advance, status, key, value, cas = pipeline_response
        # Loop while we have at least a complete header in the buffer
        while bytes_to_advance.positive?
          # If the status and key length are both zero, then this is the response
          # to the noop at the end of the pipeline
          if status.zero? && key.nil?
            finish_pipeline
            break
          end

          # If the status is zero and the key len is positive, then this is a
          # getkq response with a value that we want to set in the response hash
          values[key] = [value, cas] unless key.nil?

          # Get the next set of bytes from the buffer
          bytes_to_advance, status, key, value, cas = pipeline_response(bytes_to_advance)
        end

        values
      rescue SystemCallError, Timeout::Error, EOFError => e
        failure!(e)
      end

      def read_nonblock
        @sock.read_available
      end

      # Called after the noop response is received at the end of a set
      # of pipelined gets
      def finish_pipeline
        response_buffer.clear
        finish_request!
      end

      # Abort an earlier #pipeline_response_start. Used to signal an external
      # timeout. The underlying socket is disconnected, and the exception is
      # swallowed.
      #
      # Returns nothing.
      def pipeline_response_abort
        response_buffer.clear
        abort_request!
        return true unless @sock

        failure!(RuntimeError.new('External timeout'))
      rescue NetworkError
        true
      end

      def read(count)
        start_request!
        data = @sock.readfull(count)
        finish_request!
        data
      rescue SystemCallError, Timeout::Error, EOFError => e
        failure!(e)
      end

      def write(bytes)
        start_request!
        result = @sock.write(bytes)
        finish_request!
        result
      rescue SystemCallError, Timeout::Error => e
        failure!(e)
      end

      def connected?
        !@sock.nil?
      end

      def socket_timeout
        @socket_timeout ||= @options[:socket_timeout]
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

      def verify_state(opkey)
        failure!(RuntimeError.new('Already writing to socket')) if request_in_progress?
        reconnect_on_fork if fork_detected?
        verify_allowed_multi!(opkey) if multi?
      end

      def fork_detected?
        @pid && @pid != Process.pid
      end

      ALLOWED_MULTI_OPS = %i[add addq delete deleteq replace replaceq set setq noop].freeze
      def verify_allowed_multi!(opkey)
        return if ALLOWED_MULTI_OPS.include?(opkey)

        raise Dalli::NotPermittedMultiOpError, "The operation #{opkey} is not allowed in a multi block."
      end

      def reconnect_on_fork
        message = 'Fork detected, re-connecting child process...'
        Dalli.logger.info { message }
        reconnect! message
      end

      # Marks the server instance as needing reconnect.  Raises a
      # Dalli::NetworkError with the specified message.  Calls close
      # to clean up socket state
      def reconnect!(message)
        close
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
        raise Dalli::NetworkError, message
      end

      # Raises Dalli::NetworkError
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

      # Marks the server instance as down.  Updates the down_at state
      # and raises an Dalli::NetworkError that includes the underlying
      # error in the message.  Calls close to clean up socket state
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
        Thread.current[::Dalli::MULTI_KEY]
      end

      def cache_nils?(opts)
        return false unless opts.is_a?(Hash)

        opts[:cache_nils] ? true : false
      end

      def get(key, options = nil)
        req = RequestFormatter.standard_request(opkey: :get, key: key)
        write(req)
        @response_processor.generic_response(unpack: true, cache_nils: cache_nils?(options))
      end

      def pipelined_get(keys)
        req = +''
        keys.each do |key|
          req << RequestFormatter.standard_request(opkey: :getkq, key: key)
        end
        # Could send noop here instead of in pipeline_response_start
        write(req)
      end

      def set(key, value, ttl, cas, options)
        opkey = multi? ? :setq : :set
        process_value_req(opkey, key, value, ttl, cas, options)
      end

      def add(key, value, ttl, options)
        opkey = multi? ? :addq : :add
        cas = 0
        process_value_req(opkey, key, value, ttl, cas, options)
      end

      def replace(key, value, ttl, cas, options)
        opkey = multi? ? :replaceq : :replace
        process_value_req(opkey, key, value, ttl, cas, options)
      end

      # rubocop:disable Metrics/ParameterLists
      def process_value_req(opkey, key, value, ttl, cas, options)
        (value, bitflags) = @value_marshaller.store(key, value, options)
        ttl = TtlSanitizer.sanitize(ttl)

        req = RequestFormatter.standard_request(opkey: opkey, key: key,
                                                value: value, bitflags: bitflags,
                                                ttl: ttl, cas: cas)
        write(req)
        @response_processor.cas_response unless multi?
      end
      # rubocop:enable Metrics/ParameterLists

      def delete(key, cas)
        opkey = multi? ? :deleteq : :delete
        req = RequestFormatter.standard_request(opkey: opkey, key: key, cas: cas)
        write(req)
        @response_processor.generic_response unless multi?
      end

      def flush(ttl = 0)
        req = RequestFormatter.standard_request(opkey: :flush, ttl: ttl)
        write(req)
        @response_processor.generic_response
      end

      # This allows us to special case a nil initial value, and
      # handle it differently than a zero.  This special value
      # for expiry causes memcached to return a not found
      # if the key doesn't already exist, rather than
      # setting the initial value
      NOT_FOUND_EXPIRY = 0xFFFFFFFF

      def decr_incr(opkey, key, count, ttl, initial)
        expiry = initial ? TtlSanitizer.sanitize(ttl) : NOT_FOUND_EXPIRY
        initial ||= 0
        write(RequestFormatter.decr_incr_request(opkey: opkey, key: key,
                                                 count: count, initial: initial, expiry: expiry))
        @response_processor.decr_incr_response
      end

      def decr(key, count, ttl, initial)
        decr_incr :decr, key, count, ttl, initial
      end

      def incr(key, count, ttl, initial)
        decr_incr :incr, key, count, ttl, initial
      end

      def write_append_prepend(opkey, key, value)
        write_generic RequestFormatter.standard_request(opkey: opkey, key: key, value: value)
      end

      def write_generic(bytes)
        write(bytes)
        @response_processor.generic_response
      end

      def write_noop
        req = RequestFormatter.standard_request(opkey: :noop)
        write(req)
      end

      # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
      # We need to read all the responses at once.
      def noop
        write_noop
        @response_processor.multi_with_keys_response
      end

      def append(key, value)
        write_append_prepend :append, key, value
      end

      def prepend(key, value)
        write_append_prepend :prepend, key, value
      end

      def stats(info = '')
        req = RequestFormatter.standard_request(opkey: :stat, key: info)
        write(req)
        @response_processor.multi_with_keys_response
      end

      def reset_stats
        write_generic RequestFormatter.standard_request(opkey: :stat, key: 'reset')
      end

      def cas(key)
        req = RequestFormatter.standard_request(opkey: :get, key: key)
        write(req)
        @response_processor.data_cas_response
      end

      def version
        write_generic RequestFormatter.standard_request(opkey: :version)
      end

      def touch(key, ttl)
        ttl = TtlSanitizer.sanitize(ttl)
        write_generic RequestFormatter.standard_request(opkey: :touch, key: key, ttl: ttl)
      end

      def gat(key, ttl, options = nil)
        ttl = TtlSanitizer.sanitize(ttl)
        req = RequestFormatter.standard_request(opkey: :gat, key: key, ttl: ttl)
        write(req)
        @response_processor.generic_response(unpack: true, cache_nils: cache_nils?(options))
      end

      def connect
        Dalli.logger.debug { "Dalli::Server#connect #{name}" }

        begin
          @pid = Process.pid
          @sock = memcached_socket
          authenticate_connection if require_auth?
          @version = version # Connect socket if not authed
          up!
        rescue Dalli::DalliError # SASL auth failure
          raise
        rescue SystemCallError, Timeout::Error, EOFError, SocketError => e
          # SocketError = DNS resolution failure
          failure!(e)
        end
      end

      def memcached_socket
        if socket_type == :unix
          Dalli::Socket::UNIX.open(hostname, options)
        else
          Dalli::Socket::TCP.open(hostname, port, options)
        end
      end

      def require_auth?
        !username.nil?
      end

      def username
        @options[:username] || ENV['MEMCACHE_USERNAME']
      end

      def password
        @options[:password] || ENV['MEMCACHE_PASSWORD']
      end

      include SaslAuthentication
    end
  end
end
