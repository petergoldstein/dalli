# frozen_string_literal: true

require 'set'

module Dalli
  ##
  # Contains logic for the pipelined gets implemented by the client.
  ##
  class PipelinedGetter
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
    def process(keys, &block)
      return {} if keys.empty?

      @ring.lock do
        # Stores partial results collected during interleaved send phase
        @partial_results = {}
        servers = setup_requests(keys)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # First yield any partial results collected during interleaved send
        yield_partial_results(&block)

        servers = fetch_responses(servers, start_time, @ring.socket_timeout, &block) until servers.empty?
      end
    rescue Dalli::RetryableNetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined gets because of timeout' }
      retry
    end

    private

    def yield_partial_results
      @partial_results.each_pair do |key, value_list|
        yield @key_manager.key_without_namespace(key), value_list
      end
      @partial_results.clear
    end

    def setup_requests(keys)
      groups = groups_for_keys(keys)
      make_getkq_requests(groups)

      # TODO: How does this exit on a NetworkError
      finish_queries(groups.keys)
    end

    ##
    # Loop through the server-grouped sets of keys, writing
    # the corresponding getkq requests to the appropriate servers
    #
    # It's worth noting that we could potentially reduce bytes
    # on the wire by switching from getkq to getq, and using
    # the opaque value to match requests to responses.
    ##
    def make_getkq_requests(groups)
      groups.each do |server, keys_for_server|
        if keys_for_server.size <= INTERLEAVE_THRESHOLD
          # Small batch - send all at once (existing behavior)
          server.request(:pipelined_get, keys_for_server)
        else
          # Large batch - interleave sends with response draining
          # Pass @partial_results directly to avoid hash allocation/merge overhead
          server.request(:pipelined_get_interleaved, keys_for_server, CHUNK_SIZE, @partial_results)
        end
      rescue DalliError, NetworkError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "unable to get keys for server #{server.name}" }
      end
    end

    ##
    # This loops through the servers that have keys in
    # our set, sending the noop to terminate the set of queries.
    ##
    def finish_queries(servers)
      deleted = Set.new

      servers.each do |server|
        next unless server.connected?

        begin
          finish_query_for_server(server)
        rescue Dalli::NetworkError
          raise
        rescue Dalli::DalliError
          deleted << server
        end
      end

      servers.delete_if { |server| deleted.include?(server) }
    rescue Dalli::NetworkError
      abort_without_timeout(servers)
      raise
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

    # Swallows Dalli::NetworkError
    def abort_without_timeout(servers)
      servers.each(&:pipeline_abort)
    end

    def fetch_responses(servers, start_time, timeout, &block)
      # Remove any servers which are not connected
      servers.select!(&:connected?)
      return [] if servers.empty?

      time_left = remaining_time(start_time, timeout)
      readable_servers = servers_with_response(servers, time_left)
      if readable_servers.empty?
        abort_with_timeout(servers)
        return []
      end

      # Loop through the servers with responses, and
      # delete any from our list that are finished
      readable_servers.each do |server|
        servers.delete(server) if process_server(server, &block)
      end
      servers
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
      abort_without_timeout(servers)
      servers.each do |server|
        Dalli.logger.debug { "memcached at #{server.name} did not response within timeout" }
      end

      true # Required to simplify caller
    end

    # Processes responses from a server.  Returns true if there are no
    # additional responses from this server.
    def process_server(server)
      server.pipeline_next_responses do |key, value, cas|
        yield @key_manager.key_without_namespace(key), [value, cas]
      end

      server.pipeline_complete?
    end

    def servers_with_response(servers, timeout)
      return [] if servers.empty?

      sockets = servers.map(&:sock)
      readable, = IO.select(sockets, nil, nil, timeout)
      return [] if readable.nil?

      # For typical server counts (1-5), linear scan is faster than
      # building and looking up a hash map
      readable.filter_map { |sock| servers.find { |s| s.sock == sock } }
    end

    def groups_for_keys(*keys)
      keys.flatten!
      keys.map! { |a| @key_manager.validate_key(a.to_s) }
      groups = @ring.keys_grouped_by_server(keys)
      if (unfound_keys = groups.delete(nil))
        Dalli.logger.debug do
          "unable to get keys for #{unfound_keys.length} keys " \
            'because no matching server was found'
        end
      end
      groups
    end
  end
end
