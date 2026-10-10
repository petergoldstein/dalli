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
                     :socket_type, :up!, :down!, :write, :reconnect_down_server?, :raise_down_error, :flushed_write

      def initialize(attribs, client_options = {})
        hostname, port, socket_type, @weight, user_creds = ServerConfigParser.parse(attribs)
        warn_uri_credentials(user_creds)
        @options = client_options.merge(user_creds)
        @raw_mode = client_options[:raw]
        @verify_reply_keys = client_options[:verify_reply_keys] ? true : false
        @value_marshaller = @raw_mode ? StringMarshaller.new(@options) : ValueMarshaller.new(@options)
        @connection_manager = ConnectionManager.new(hostname, port, socket_type, @options)
      end

      # Returns true if client is in raw mode (no serialization/compression).
      # In raw mode, we can skip requesting bitflags from the server.
      def raw_mode?
        @raw_mode
      end

      # True when values should come back as stored: the client is in raw mode,
      # or this request passed raw: true. Retrieval paths use it to skip
      # requesting flags, so a stored value is never deserialized or
      # decompressed for a caller who asked for raw bytes.
      def raw_request?(options)
        raw_mode? || (options.is_a?(Hash) && options[:raw]) ? true : false
      end

      # Chokepoint method for error handling and ensuring liveness
      def request(opkey, *args)
        verify_state(opkey)

        begin
          request_completed = false
          @connection_manager.start_request!
          drain_pending_quiet_responses(opkey)
          response = send(opkey, *args)
          # Quiet requests can leave replies on the socket; remember that so a
          # later non-quiet request knows to read them first
          @connection_manager.mark_quiet_responses_pending! if quiet? && opkey != :noop

          # pipelined_get/pipelined_get_interleaved emit query but don't read the response(s)
          @connection_manager.finish_request! unless %i[pipelined_get pipelined_get_interleaved].include?(opkey)

          request_completed = true
          response
        rescue Dalli::MarshalError, Dalli::ValueOverMaxSize => e
          log_marshal_err(args.first, e) if e.is_a?(Dalli::MarshalError)
          # Raised only while the connection is clean: a value is marshalled
          # before any of its request is written, and write_multi_req raises
          # only after reading every reply. Closing the connection would
          # discard earlier quiet writes still waiting in the write buffer.
          @connection_manager.abort_request!
          request_completed = true
          raise
        rescue Dalli::DalliError
          raise
        rescue StandardError => e
          log_unexpected_err(e)
          close
          raise
        ensure
          # If the begin block didn't complete -- any exception, including a
          # non-StandardError such as Async::Stop or Thread#kill, which the
          # rescue clauses above never see -- tear down the connection so a
          # half-used client isn't returned to the pool.
          #
          # The local flag is deliberate: reading $ERROR_INFO here would see
          # the *outer* exception when `request` is called from inside a
          # rescue clause (a common cache-fallback shape), and would then
          # falsely tear down the pipelined_get happy path, which leaves
          # @request_in_progress true on purpose until the caller drains.
          close unless request_completed
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
        # Use ensure_ready instead of reset to preserve any data already buffered
        # during interleaved pipelined get draining
        response_buffer.ensure_ready
      end

      # Attempt to receive and parse as many key/value pairs as possible
      # from this server. After #pipeline_response_setup, this should be invoked
      # repeatedly whenever this server's socket is readable until
      # #pipeline_complete?.
      #
      # When a block is given, yields (key, value, cas) for each response,
      # avoiding intermediate Hash allocation. Returns nil.
      # Without a block, returns a Hash of { key => [value, cas] }.
      def pipeline_next_responses(&block)
        return abandon_pipeline if @pipeline_out_of_step

        reconnect_on_pipeline_complete!
        values = nil

        # Only the read is socket I/O. The caller's block runs below, outside
        # this rescue, so an Errno or Timeout::Error it raises reaches the
        # caller instead of being mistaken for a network failure (which closed
        # the connection and retried the whole get_multi, yielding keys twice).
        begin
          response_buffer.read
        rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
          @connection_manager.error_on_request!(e)
        end

        status, cas, key, value = response_buffer.process_single_getk_response
        # status is not nil only if we have a full response to parse
        # in the buffer
        until status.nil?
          # If the status is ok and key is nil, then this is the response
          # to the noop at the end of the pipeline
          finish_pipeline && break if status && key.nil?

          # A key that wasn't requested means the replies are out of step
          # (see expect_reply_keys): keep what was read so far, drop the rest
          if unexpected_reply_key?(key)
            abandon_pipeline
            break
          end

          # If the status is ok and the key is not nil, then this is a
          # getkq response with a value that we want to set in the response hash
          unless key.nil?
            if block
              yield key, value, cas
            else
              values ||= {}
              values[key] = [value, cas]
            end
          end

          # Get the next response from the buffer
          status, cas, key, value = response_buffer.process_single_getk_response
        end

        values || {}
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Abort current pipelined get. Generally used to signal an external
      # timeout during pipelined get.  The underlying socket is
      # disconnected, and the exception is swallowed.
      #
      # Returns nothing.
      def pipeline_abort
        response_buffer.clear
        @connection_manager.abort_request!
        return true unless connected?

        # Closes the connection, which ensures that our connection is in a
        # clean state for future requests. The get_multi ran out of time
        # overall rather than hitting a socket error, so it doesn't count
        # toward socket_max_failures: two slow get_multis in a row would
        # otherwise mark a healthy server down.
        Dalli.logger.warn { "#{name} didn't finish a get_multi within socket_timeout; closing the connection" }
        @connection_manager.close
        true
      end

      # Did the last call to #pipeline_response_setup complete successfully?
      def pipeline_complete?
        !response_buffer.in_progress?
      end

      def quiet?
        Thread.current[::Dalli::QUIET]
      end
      alias multi? quiet?

      # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

      private

      URI_CREDENTIAL_WARNING = 'Dalli 5.0 removed SASL authentication. ' \
                               'Credentials in memcached:// URIs are ignored.'
      private_constant :URI_CREDENTIAL_WARNING

      def warn_uri_credentials(user_creds)
        return if user_creds[:username].nil? && user_creds[:password].nil?

        Dalli.logger.warn(URI_CREDENTIAL_WARNING)
      end

      ALLOWED_QUIET_OPS = %i[add replace set delete incr decr append prepend flush noop].freeze
      private_constant :ALLOWED_QUIET_OPS

      # Reads the replies still pending from quiet requests before any
      # non-quiet request, which reads a reply of its own. A quiet block reads
      # them at its end, but the connection is shared: another thread or fiber
      # (quiet? is fiber-local) can make a request while the block is still
      # open, and would otherwise read the block's replies as its own. The
      # noop also sends any quiet requests still buffered.
      def drain_pending_quiet_responses(opkey)
        return unless @connection_manager.quiet_responses_pending? && opkey != :noop && !quiet?

        noop
      end

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
        @version = version
        up!
      end

      def pipelined_get(keys)
        # Clear buffer to remove any stale data from interrupted operations.
        # Use clear (not reset) to keep pipeline_complete? = true, which is
        # the expected state before pipeline_response_setup is called.
        response_buffer.clear
        expect_reply_keys(keys)

        req = +''
        keys.each do |key|
          req << quiet_get_request(key)
        end
        # Could send noop here instead of in pipeline_response_setup
        write(req)
      end

      # For large batches, interleave writing requests with draining responses.
      # This prevents socket buffer deadlock when sending many keys.
      # Populates the provided results hash with any responses drained during send.
      def pipelined_get_interleaved(keys, chunk_size, results)
        # Initialize the response buffer for draining during send phase
        response_buffer.ensure_ready
        expect_reply_keys(keys)

        keys.each_slice(chunk_size) do |chunk|
          # Build and write this chunk of requests
          req = +''
          chunk.each do |key|
            req << quiet_get_request(key)
          end
          write(req)
          @connection_manager.flush

          # Drain any available responses directly into results hash
          drain_pipeline_responses(results)
        end
      end

      # Non-blocking read and processing of any available pipeline responses.
      # Used during interleaved pipelined gets to prevent buffer deadlock.
      # Populates the provided results hash directly to avoid allocation overhead.
      def drain_pipeline_responses(results)
        return unless connected?

        # Non-blocking check if socket has data available
        return unless sock.wait_readable(0)

        # Read available data without blocking
        response_buffer.read

        # Process any complete responses in the buffer
        loop do
          status, cas, key, value = response_buffer.process_single_getk_response
          break if status.nil? # No complete response available

          # Handled by the next pipeline_next_responses, once sending is done
          if unexpected_reply_key?(key)
            @pipeline_out_of_step = true
            break
          end

          results[key] = [value, cas] unless key.nil?
        end
      rescue SystemCallError, Dalli::NetworkError
        # Ignore errors during drain - they'll be handled in fetch_responses
        nil
      end

      def response_buffer
        @response_buffer ||= ResponseBuffer.new(@connection_manager, response_processor)
      end

      # A multi-get only accepts replies for the keys it asked for. memcached
      # names an item created by auto-create (ma or mg with N) for a
      # base64-encoded key by its raw bytes, without the b flag; such a key
      # can contain spaces or CR/LF, which split the reply header and make the
      # replies after it parse as different ones. A key that wasn't requested
      # is how that shows up.
      # Only with the verify_reply_keys option, since building the set costs a
      # multi-get about 15%. Dalli itself no longer creates such items (see
      # Meta#decr_incr); the check guards against ones that older versions or
      # other clients created, on memcached versions with the behavior.
      def expect_reply_keys(keys)
        @pipeline_out_of_step = false
        @expected_reply_keys = (keys.to_set { |k| reply_key_form(k) } if @verify_reply_keys)
      end

      def unexpected_reply_key?(key)
        !key.nil? && @expected_reply_keys && !@expected_reply_keys.include?(reply_key_form(key))
      end

      # Keys compared as bytes; ASCII keys compare equal in any encoding as is
      def reply_key_form(key)
        key.ascii_only? ? key : key.b
      end

      # Keeps what was read, drops the rest of this server's replies, and
      # closes the connection so nothing unread is left on it. Not a socket
      # failure, so it doesn't count toward socket_max_failures; the keys not
      # read are simply missing from the result.
      def abandon_pipeline
        Dalli.logger.warn { "#{name} replied to a get_multi with a key that wasn't requested; closing the connection" }
        @pipeline_out_of_step = false
        response_buffer.clear
        @connection_manager.close
        {}
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

      # The single-server set_multi path passes its whole pairs hash as the
      # first argument; log only its keys, never the values
      def log_marshal_err(key, err)
        key = key.keys.join("', '") if key.is_a?(Hash)
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
