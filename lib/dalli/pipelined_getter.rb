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
        requests = setup_requests(keys)
        fetch_responses(requests, @ring.socket_timeout, &block)
      end
    rescue NetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined gets because of timeout' }
      retry
    end

    def setup_requests(all_keys)
      groups_for_keys(all_keys).to_h do |server, keys|
        # It's worth noting that we could potentially reduce bytes
        # on the wire by switching from getkq to getq, and using
        # the opaque value to match requests to responses.
        [server, server.pipelined_get_request(keys)]
      end
    end

    def finish_query_for_server(server)
      server.finish_pipeline_request
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

    def fetch_responses(requests, timeout, &block)
      # FIXME: this was here. why. where should it go?
      # Remove any servers which are not connected
      # servers.delete_if { |s| !s.connected? }

      start_time = Time.now
      servers = requests.keys

      # FIXME: this was executed before the finish request was sent. Why?
      servers.delete_if { |s| !s.alive? }

      # could be postponed to after the first write
      servers.each(&:pipeline_response_setup)

      until servers.empty?
        time_left = remaining_time(start_time, timeout)
        servers = read_write_select(servers, requests, time_left, &block)
      end
    rescue NetworkError
      # Abort and raise if we encountered a network error.  This triggers
      # a retry at the top level.
      abort_without_timeout(servers)
      raise
    end

    def read_write_select(servers, requests, time_left, &block)
      # TODO: - This is a bit challenging.  Essentially the PipelinedGetter
      # is a reactor, but without the benefit of a Fiber or separate thread.
      # My suspicion is that we may want to try and push this down into the
      # individual servers, but I'm not sure.  For now, we keep the
      # mapping between the alerted object (the socket) and the
      # corrresponding server here.
      server_map = servers.each_with_object({}) { |s, h| h[s.sock] = s }

      readable, writable, = IO.select(server_map.keys, server_map.keys,
                                      nil, time_left)

      if readable.nil?
        abort_with_timeout(servers)
        return []
      end

      writable.each do |socket|
        server = server_map[socket]
        process_writable(server, servers, requests)
      end

      readable.each do |socket|
        server = server_map[socket]

        servers.delete(server) if process_server(server, &block)
      end

      servers
    end

    def process_writable(server, servers, requests)
      request = requests[server]
      return unless request

      new_request = server_pipelined_get(server, request)

      if new_request.empty?
        requests.delete(server)

        begin
          finish_query_for_server(server)
        rescue Dalli::NetworkError
          raise
        rescue Dalli::DalliError
          servers.delete(server)
        end
      else
        requests[server] = new_request
      end
    rescue Dalli::NetworkError
      abort_without_timeout(servers)
      raise
    rescue DalliError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { "unable to get keys for server #{server.name}" }
    end

    def server_pipelined_get(server, request)
      buffer_size = server.socket_sndbuf
      chunk = request[0..buffer_size]
      written = server.request(:pipelined_get, chunk)
      return if written == :wait_writable

      request[written..]
    rescue Dalli::NetworkError
      raise
    rescue DalliError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { "unable to get keys for server #{server.name}" }
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
