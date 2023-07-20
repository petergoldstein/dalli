# frozen_string_literal: true

require 'forwardable'
require 'socket'
require 'timeout'

module Dalli
  module Protocol
    ##
    # Base class for a single Memcached server, containing logic common to all
    # protocols.  Contains logic for managing connection state to the server and value
    # handling.
    ##
    class Base
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
      end

      # Chokepoint method for error handling and ensuring liveness
      def request(opkey, *args)
        verify_state(opkey)

        begin
          @connection_manager.start_request!
          response = send(opkey, *args)

          # pipelined_get emit query but doesn't read the response(s)
          @connection_manager.finish_request! unless opkey == :pipelined_get

          response
        rescue Dalli::MarshalError => e
          log_marshal_err(args.first, e)
          raise
        rescue Dalli::DalliError
          raise
        rescue StandardError => e
          log_unexpected_err(e)
          close
          raise
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
        verify_pipelined_state(:getkq)
        write_noop
        response_buffer.reset
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

        status, cas, key, value = response_buffer.process_single_getk_response
        # status is not nil only if we have a full response to parse
        # in the buffer
        until status.nil?
          # If the status is ok and key is nil, then this is the response
          # to the noop at the end of the pipeline
          finish_pipeline && break if status && key.nil?

          # If the status is ok and the key is not nil, then this is a
          # getkq response with a value that we want to set in the response hash
          values[key] = [value, cas] unless key.nil?

          # Get the next response from the buffer
          status, cas, key, value = response_buffer.process_single_getk_response
        end

        values
      rescue SystemCallError, *TIMEOUT_ERRORS, EOFError => e
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
        @options[:username] || ENV.fetch('MEMCACHE_USERNAME', nil)
      end

      def password
        @options[:password] || ENV.fetch('MEMCACHE_PASSWORD', nil)
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

      ALLOWED_QUIET_OPS = %i[add replace set delete incr decr append prepend flush noop].freeze
      def verify_allowed_quiet!(opkey)
        return if ALLOWED_QUIET_OPS.include?(opkey)

        raise Dalli::NotPermittedMultiOpError, "The operation #{opkey} is not allowed in a quiet block."
      end

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

      def verify_pipelined_state(_opkey)
        @connection_manager.confirm_in_progress!
        raise_down_error unless connected?
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

      def cache_nils?(opts)
        return false unless opts.is_a?(Hash)

        opts[:cache_nils] ? true : false
      end

      def connect
        @connection_manager.establish_connection
        authenticate_connection if require_auth?
        @version = version # Connect socket if not authed
        up!
      end

      def pipelined_get(keys)
        req = +''
        keys.each do |key|
          req << quiet_get_request(key)
        end
        # Could send noop here instead of in pipeline_response_setup
        write(req)
      end

      def response_buffer
        @response_buffer ||= ResponseBuffer.new(@connection_manager, response_processor)
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
    end
  end
end
