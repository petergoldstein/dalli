# frozen_string_literal: true

module Dalli
  ##
  # Contains logic for the pipelined gets implemented by the client.
  ##
  class PipelinedGetter
    include KeyGrouping

    # For large batches, interleave sends with response draining to prevent
    # socket buffer deadlock. Only kicks in above this threshold.
    INTERLEAVE_THRESHOLD = 10_000

    # Number of keys to send before draining responses during interleaved mode
    CHUNK_SIZE = 10_000

    def initialize(ring, key_manager)
      @ring = ring
      @key_manager = key_manager
    end

    ##
    # Yields, one at a time, keys and their values+attributes.
    #
    # `req_options` accepts :p_token/:l_token, applied to every key in the batch.
    #
    # With return_cas: false the CAS value is not requested, and each yielded
    # CAS is 0.
    #
    # A transient network error is retried automatically. If a server remains
    # unreachable after retrying, raises Dalli::NetworkError.
    #
    # A value that can't be deserialized raises Dalli::UnmarshalError, as get
    # does, once every server's replies are read, so the connections stay in
    # step. The other values are yielded first.
    #
    def process(keys, req_options = nil, return_cas: true, &block)
      return {} if keys.empty?

      @ring.lock do
        # The servers with replies still to read, updated in place
        servers = []
        begin
          # Stores partial results collected during interleaved send phase
          @partial_results = {}
          @unmarshal_error = nil
          @caller_keys = @key_manager.caller_keys_by_wire_key(keys.flatten)
          setup_requests(servers, @caller_keys.keys, req_options, return_cas: return_cas)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # First yield any partial results collected during interleaved send
          yield_partial_results(&block)

          fetch_responses(servers, start_time, @ring.socket_timeout, &block) until servers.empty?
          raise @unmarshal_error if @unmarshal_error
        ensure
          abort_unfinished(servers)
        end
      end
    rescue Dalli::RetryableNetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined gets because of timeout' }
      retry
    end

    ##
    # Stale-aware bulk get across servers.  Returns { key => metadata Hash } for
    # the keys that were found; see Protocol::Meta#read_multi_with_metadata_req
    # for why misses are absent rather than present with miss: true.
    #
    # Unlike #process this issues one request per server and reads its full
    # response before moving on, rather than pipelining across servers: the
    # metadata path has no interleaving support, and the stale-aware callers it
    # serves fetch far smaller batches than get_multi does.
    #
    # A value that can't be deserialized raises Dalli::UnmarshalError, once its
    # server's replies are read. The servers after it aren't asked.
    #
    # `req_options` accepts :p_token/:l_token, applied to every key in the batch.
    #
    # A transient network error is retried automatically. A terminal
    # Dalli::NetworkError propagates instead of returning partial metadata.
    #
    def process_with_metadata(keys, req_options = nil)
      return {} if keys.empty?

      @ring.lock do
        results = {}
        caller_keys = @key_manager.caller_keys_by_wire_key(keys)
        groups_for_keys(caller_keys.keys, 'get').each do |server, keys_for_server|
          server.request(:read_multi_with_metadata_req, keys_for_server, req_options).each_pair do |key, metadata|
            caller_key = @key_manager.caller_key(caller_keys, key)
            results[caller_key] = metadata if caller_key
          end
        rescue Dalli::NetworkError, Dalli::UnmarshalError
          raise
        rescue DalliError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "unable to get keys for server #{server.name}" }
        end
        results
      end
    rescue Dalli::RetryableNetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined get with metadata because of network error' }
      retry
    end

    private

    def yield_partial_results
      @partial_results.each_pair do |key, value_list|
        caller_key = @key_manager.caller_key(@caller_keys, key)
        yield caller_key, value_list if caller_key
      end
      @partial_results.clear
    end

    # Sends each server's queries and its terminating noop before building
    # the next server's, so memcached is already answering the first servers
    # while the rest are prepared. Adds the servers with a pending response
    # to started.
    def setup_requests(started, wire_keys, req_options = nil, return_cas: true)
      groups_for_keys(wire_keys, 'get').each do |server, keys_for_server|
        make_getkq_request(server, keys_for_server, req_options, return_cas: return_cas)
        next unless server.connected?

        started << server
        finish_query_for_server(server)
      rescue Dalli::NetworkError
        abort_without_timeout(started)
        raise
      rescue Dalli::DalliError
        started.delete(server)
      end
    end

    ##
    # Writes the getkq requests for one server's keys
    #
    # It's worth noting that we could potentially reduce bytes
    # on the wire by switching from getkq to getq, and using
    # the opaque value to match requests to responses.
    ##
    def make_getkq_request(server, keys_for_server, req_options = nil, return_cas: true)
      if keys_for_server.size <= INTERLEAVE_THRESHOLD
        # Small batch - send all at once (existing behavior)
        server.request(:pipelined_get, keys_for_server, req_options, return_cas)
      else
        # Large batch - interleave sends with response draining
        # Pass @partial_results directly to avoid hash allocation/merge overhead
        server.request(:pipelined_get_interleaved, keys_for_server, CHUNK_SIZE, @partial_results, req_options)
      end
    # NetworkError (which RetryableNetworkError subclasses) must propagate:
    # #process's top-level rescue retries the whole pipelined get on it. This
    # rescue used to catch DalliError and NetworkError together -- since
    # NetworkError < DalliError, that silently swallowed RetryableNetworkError
    # too, dropping this server's keys from the result on a transient hiccup
    # instead of retrying, with nothing surfaced above debug-level logging.
    # Only a non-network DalliError (this server genuinely can't serve these
    # keys) should be swallowed here.
    rescue Dalli::NetworkError
      raise
    rescue DalliError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { "unable to get keys for server #{server.name}" }
    end

    def finish_query_for_server(server)
      server.pipeline_response_setup
    rescue Dalli::NetworkError
      raise
    rescue Dalli::DalliError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { "Results from server: #{server.name} will be missing from the results" }
      raise
    end

    # Swallows Dalli::NetworkError. Empties servers, so they aren't aborted
    # again.
    def abort_without_timeout(servers)
      servers.each(&:pipeline_abort)
      servers.clear
    end

    # When #process stops before reading every server's replies (the caller's
    # block raises or breaks, a Timeout.timeout fires), the rest are still on
    # the socket and some may be in the response buffer. Closing those
    # connections keeps them from being read as a later request's replies.
    # Aborts that #process already handled emptied servers.
    def abort_unfinished(servers)
      servers.each { |server| server.pipeline_abort(timed_out: false) }
      servers.clear
    end

    # Reads the replies available, removing finished servers from servers
    def fetch_responses(servers, start_time, timeout, &block)
      # Remove any servers which are not connected
      servers.select!(&:connected?)
      return if servers.empty?

      time_left = remaining_time(start_time, timeout)
      readable_servers = servers_with_response(servers, time_left)
      return abort_with_timeout(servers) if readable_servers.empty?

      # Loop through the servers with responses, and
      # delete any from our list that are finished
      readable_servers.each do |server|
        servers.delete(server) if process_server(server, &block)
      end
    rescue NetworkError
      # Abort and raise if we encountered a network error.  This triggers
      # a retry at the top level on RetryableNetworkError.
      abort_without_timeout(servers)
      raise
    end

    def remaining_time(start, timeout)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      return 0 if elapsed > timeout

      timeout - elapsed
    end

    # Swallows Dalli::NetworkError
    def abort_with_timeout(servers)
      servers.each do |server|
        Dalli.logger.debug { "memcached at #{server.name} did not response within timeout" }
      end
      abort_without_timeout(servers)
    end

    # Processes responses from a server.  Returns true if there are no
    # additional responses from this server.
    #
    # A value that couldn't be deserialized is raised once the server's
    # replies are all read; it's held until the other servers' are too.
    def process_server(server)
      # A reply names the key as sent; it's yielded under the caller's key
      server.pipeline_next_responses do |key, value, cas|
        caller_key = @key_manager.caller_key(@caller_keys, key)
        yield caller_key, [value, cas] if caller_key
      end

      server.pipeline_complete?
    rescue Dalli::UnmarshalError => e
      # Raised by the caller's block, with replies still to read
      raise unless server.pipeline_complete?

      @unmarshal_error ||= e
      true
    end

    def servers_with_response(servers, timeout)
      return [] if servers.empty?

      sockets = servers.map(&:sock)
      readable, = IO.select(sockets, nil, nil, timeout)
      return [] if readable.nil?

      # For typical server counts (1-5), linear scan is faster than
      # building and looking up a hash map. Array#index scans in C and
      # reuses the sockets already fetched above.
      readable.filter_map { |sock| (idx = sockets.index(sock)) && servers[idx] }
    end
  end
end
