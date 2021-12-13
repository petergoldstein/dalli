# frozen_string_literal: true

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

      attr_accessor :weight, :options

      def_delegators :@value_marshaller, :serializer, :compressor, :compression_min_size, :compress_by_default?
      def_delegators :@connection_manager, :name, :sock, :hostname, :port, :close, :connected?, :socket_timeout,
                     :socket_type, :up!, :down!, :write, :reconnect_down_server?, :raise_down_error

      def initialize(attribs, client_options = {})
        hostname, port, socket_type, @weight, user_creds = ServerConfigParser.parse(attribs)
        @options = client_options.merge(user_creds)
        @value_marshaller = ValueMarshaller.new(@options)
        @connection_manager = ConnectionManager.new(hostname, port, socket_type, @options)
        @response_processor = ResponseProcessor.new(@connection_manager, @value_marshaller)
      end

      # Chokepoint method for error handling and ensuring liveness
      def request(opkey, *args)
        verify_state(opkey)

        begin
          send(opkey, *args)
        rescue Dalli::MarshalError => e
          log_marshal_err(args.first, e)
          raise
        rescue Dalli::DalliError
          raise
        rescue StandardError => e
          log_unexpected_err(e)
          down!
        end
      end

      ##
      # Boolean method used by clients of this class to determine if this
      # particular memcached instance is available for use.
      def alive?
        ensure_connected!
      rescue Dalli::NetworkError
        # ensure_connected! raises a NetworkError if connection fails.  We
        # want to capture that error and convert it to a boolean value here.
        false
      end

      def lock!; end

      def unlock!; end

      # Start reading key/value pairs from this connection. This is usually called
      # after a series of GETKQ commands. A NOOP is sent, and the server begins
      # flushing responses for kv pairs that were found.
      #
      # Returns nothing.
      def pipeline_response_setup
        verify_state(:getkq)
        write_noop
        response_buffer.reset
        @connection_manager.start_request!
      end

      # Attempt to receive and parse as many key/value pairs as possible
      # from this server. After #pipeline_response_setup, this should be invoked
      # repeatedly whenever this server's socket is readable until
      # #pipeline_complete?.
      #
      # Returns a Hash of kv pairs received.
      def pipeline_next_responses
        reconnect_on_pipeline_complete!
        values = {}

        response_buffer.read

        resp_header, key, value = pipeline_response
        # resp_header is not nil only if we have a full response to parse
        # in the buffer
        while resp_header
          # If the status is ok and key is nil, then this is the response
          # to the noop at the end of the pipeline
          finish_pipeline && break if resp_header.ok? && key.nil?

          # If the status is ok and the key is not nil, then this is a
          # getkq response with a value that we want to set in the response hash
          values[key] = [value, resp_header.cas] unless key.nil?

          # Get the next response from the buffer
          resp_header, key, value = pipeline_response
        end

        values
      rescue SystemCallError, Timeout::Error, EOFError => e
        @connection_manager.error_on_request!(e)
      end

      # Abort current pipelined get. Generally used to signal an external
      # timeout during pipelined get.  The underlying socket is
      # disconnected, and the exception is swallowed.
      #
      # Returns nothing.
      def pipeline_abort
        response_buffer.clear
        @connection_manager.abort_request!
        return true unless connected?

        # Closes the connection, which ensures that our connection
        # is in a clean state for future requests
        @connection_manager.error_on_request!('External timeout')
      rescue NetworkError
        true
      end

      # Did the last call to #pipeline_response_setup complete successfully?
      def pipeline_complete?
        !response_buffer.in_progress?
      end

      def username
        @options[:username] || ENV['MEMCACHE_USERNAME']
      end

      def password
        @options[:password] || ENV['MEMCACHE_PASSWORD']
      end

      def require_auth?
        !username.nil?
      end

      def quiet?
        Thread.current[::Dalli::QUIET]
      end
      alias multi? quiet?

      # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

      private

      ##
      # Checks to see if we can execute the specified operation.  Checks
      # whether the connection is in use, and whether the command is allowed
      ##
      def verify_state(opkey)
        @connection_manager.confirm_ready!
        verify_allowed_quiet!(opkey) if quiet?

        # The ensure_connected call has the side effect of connecting the
        # underlying socket if it is not connected, or there's been a disconnect
        # because of timeout or other error.  Method raises an error
        # if it can't connect
        raise_down_error unless ensure_connected!
      end

      # The socket connection to the underlying server is initialized as a side
      # effect of this call.  In fact, this is the ONLY place where that
      # socket connection is initialized.
      #
      # Both this method and connect need to be in this class so we can do auth
      # as required
      #
      # Since this is invoked exclusively in verify_state!, we don't need to worry about
      # thread safety.  Using it elsewhere may require revisiting that assumption.
      def ensure_connected!
        return true if connected?
        return false unless reconnect_down_server?

        connect # This call needs to be in this class so we can do auth
        connected?
      end

      ALLOWED_QUIET_OPS = %i[add replace set delete incr decr append prepend flush noop].freeze
      def verify_allowed_quiet!(opkey)
        return if ALLOWED_QUIET_OPS.include?(opkey)

        raise Dalli::NotPermittedMultiOpError, "The operation #{opkey} is not allowed in a quiet block."
      end

      def cache_nils?(opts)
        return false unless opts.is_a?(Hash)

        opts[:cache_nils] ? true : false
      end

      # Retrieval Commands
      def get(key, options = nil)
        req = RequestFormatter.standard_request(opkey: :get, key: key)
        write(req)
        @response_processor.generic_response(unpack: true, cache_nils: cache_nils?(options))
      end

      def gat(key, ttl, options = nil)
        ttl = TtlSanitizer.sanitize(ttl)
        req = RequestFormatter.standard_request(opkey: :gat, key: key, ttl: ttl)
        write(req)
        @response_processor.generic_response(unpack: true, cache_nils: cache_nils?(options))
      end

      def touch(key, ttl)
        ttl = TtlSanitizer.sanitize(ttl)
        write(RequestFormatter.standard_request(opkey: :touch, key: key, ttl: ttl))
        @response_processor.generic_response
      end

      # TODO: This is confusing, as there's a cas command in memcached
      # and this isn't it.  Maybe rename?  Maybe eliminate?
      def cas(key)
        req = RequestFormatter.standard_request(opkey: :get, key: key)
        write(req)
        @response_processor.data_cas_response
      end

      # Storage Commands
      def set(key, value, ttl, cas, options)
        opkey = quiet? ? :setq : :set
        storage_req(opkey, key, value, ttl, cas, options)
      end

      def add(key, value, ttl, options)
        opkey = quiet? ? :addq : :add
        storage_req(opkey, key, value, ttl, 0, options)
      end

      def replace(key, value, ttl, cas, options)
        opkey = quiet? ? :replaceq : :replace
        storage_req(opkey, key, value, ttl, cas, options)
      end

      # rubocop:disable Metrics/ParameterLists
      def storage_req(opkey, key, value, ttl, cas, options)
        (value, bitflags) = @value_marshaller.store(key, value, options)
        ttl = TtlSanitizer.sanitize(ttl)

        req = RequestFormatter.standard_request(opkey: opkey, key: key,
                                                value: value, bitflags: bitflags,
                                                ttl: ttl, cas: cas)
        write(req)
        @response_processor.storage_response unless quiet?
      end
      # rubocop:enable Metrics/ParameterLists

      def append(key, value)
        opkey = quiet? ? :appendq : :append
        write_append_prepend opkey, key, value
      end

      def prepend(key, value)
        opkey = quiet? ? :prependq : :prepend
        write_append_prepend opkey, key, value
      end

      def write_append_prepend(opkey, key, value)
        write(RequestFormatter.standard_request(opkey: opkey, key: key, value: value))
        @response_processor.no_body_response unless quiet?
      end

      # Delete Commands
      def delete(key, cas)
        opkey = quiet? ? :deleteq : :delete
        req = RequestFormatter.standard_request(opkey: opkey, key: key, cas: cas)
        write(req)
        @response_processor.no_body_response unless quiet?
      end

      # Arithmetic Commands
      def decr(key, count, ttl, initial)
        opkey = quiet? ? :decrq : :decr
        decr_incr opkey, key, count, ttl, initial
      end

      def incr(key, count, ttl, initial)
        opkey = quiet? ? :incrq : :incr
        decr_incr opkey, key, count, ttl, initial
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
        @response_processor.decr_incr_response unless quiet?
      end

      # Other Commands
      def flush(ttl = 0)
        opkey = quiet? ? :flushq : :flush
        write(RequestFormatter.standard_request(opkey: opkey, ttl: ttl))
        @response_processor.no_body_response unless quiet?
      end

      # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
      # We need to read all the responses at once.
      def noop
        write_noop
        @response_processor.multi_with_keys_response
      end

      def stats(info = '')
        req = RequestFormatter.standard_request(opkey: :stat, key: info)
        write(req)
        @response_processor.multi_with_keys_response
      end

      def reset_stats
        write(RequestFormatter.standard_request(opkey: :stat, key: 'reset'))
        @response_processor.generic_response
      end

      def version
        write(RequestFormatter.standard_request(opkey: :version))
        @response_processor.generic_response
      end

      def write_noop
        req = RequestFormatter.standard_request(opkey: :noop)
        write(req)
      end

      def connect
        @connection_manager.establish_connection
        authenticate_connection if require_auth?
        @version = version # Connect socket if not authed
        up!
      rescue Dalli::DalliError
        raise
      end

      def pipelined_get(keys)
        req = +''
        keys.each do |key|
          req << RequestFormatter.standard_request(opkey: :getkq, key: key)
        end
        # Could send noop here instead of in pipeline_response_setup
        write(req)
      end

      def response_buffer
        @response_buffer ||= ResponseBuffer.new(@connection_manager, @response_processor)
      end

      def pipeline_response
        response_buffer.process_single_getk_response
      end

      # Called after the noop response is received at the end of a set
      # of pipelined gets
      def finish_pipeline
        response_buffer.clear
        @connection_manager.finish_request!

        true # to simplify response
      end

      def reconnect_on_pipeline_complete!
        @connection_manager.reconnect! 'pipelined get has completed' if pipeline_complete?
      end

      def log_marshal_err(key, err)
        Dalli.logger.error "Marshalling error for key '#{key}': #{err.message}"
        Dalli.logger.error 'You are trying to cache a Ruby object which cannot be serialized to memcached.'
      end

      def log_unexpected_err(err)
        Dalli.logger.error "Unexpected exception during Dalli request: #{err.class.name}: #{err.message}"
        Dalli.logger.error err.backtrace.join("\n\t")
      end

      include SaslAuthentication
    end
  end
end
