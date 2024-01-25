# frozen_string_literal: true

module Dalli
  ##
  # Contains logic for the pipelined gets implemented by the client.
  ##
  class PipelinedGetter
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
        servers = setup_requests(keys)
        start_time = Time.now
        servers = fetch_responses(servers, start_time, @ring.socket_timeout, &block) until servers.empty?
      end
    rescue NetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined gets because of timeout' }
      retry
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
        server.request(:pipelined_get, keys_for_server)
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
      deleted = []

      servers.each do |server|
        next unless server.connected?

        begin
          finish_query_for_server(server)
        rescue Dalli::NetworkError
          raise
        rescue Dalli::DalliError
          deleted.append(server)
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
      servers.delete_if { |s| !s.connected? }
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
      # a retry at the top level.
      abort_without_timeout(servers)
      raise
    end

    def remaining_time(start, timeout)
      elapsed = Time.now - start
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
      server.pipeline_next_responses.each_pair do |key, value_list|
        yield @key_manager.key_without_namespace(key), value_list
      end

      server.pipeline_complete?
    end

    def servers_with_response(servers, timeout)
      return [] if servers.empty?

      # TODO: - This is a bit challenging.  Essentially the PipelinedGetter
      # is a reactor, but without the benefit of a Fiber or separate thread.
      # My suspicion is that we may want to try and push this down into the
      # individual servers, but I'm not sure.  For now, we keep the
      # mapping between the alerted object (the socket) and the
      # corrresponding server here.
      server_map = servers.each_with_object({}) { |s, h| h[s.sock] = s }

      readable, = IO.select(server_map.keys, nil, nil, timeout)
      return [] if readable.nil?

      readable.map { |sock| server_map[sock] }
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
