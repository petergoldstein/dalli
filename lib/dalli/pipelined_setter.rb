# frozen_string_literal: true

module Dalli
  ##
  # Contains logic for the pipelined set operations implemented by the client.
  # Efficiently writes multiple key-value pairs by grouping requests by server
  # and using quiet mode to minimize round trips.
  ##
  class PipelinedSetter
    def initialize(ring, key_manager)
      @ring = ring
      @key_manager = key_manager
    end

    ##
    # Writes multiple key-value pairs to memcached.
    # Raises an error if any server is unavailable.
    #
    # @param hash [Hash] key-value pairs to set
    # @param ttl [Integer] time-to-live in seconds
    # @param req_options [Hash] options passed to each set operation
    # @return [void]
    ##
    def process(hash, ttl, req_options)
      return if hash.empty?

      @ring.lock do
        servers = setup_requests(hash, ttl, req_options)
        finish_requests(servers)
      end
    rescue Dalli::RetryableNetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined sets because of network error' }
      retry
    end

    private

    def setup_requests(hash, ttl, req_options)
      groups = groups_for_keys(hash.keys)
      make_set_requests(groups, hash, ttl, req_options)
      groups.keys
    end

    ##
    # Loop through the server-grouped sets of keys, writing
    # the corresponding quiet set requests to the appropriate servers
    ##
    def make_set_requests(groups, hash, ttl, req_options)
      groups.each do |server, keys_for_server|
        keys_for_server.each do |key|
          original_key = @key_manager.key_without_namespace(key)
          value = hash[original_key]
          server.request(:pipelined_set, key, value, ttl, req_options)
        rescue DalliError, NetworkError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "unable to set key #{key} for server #{server.name}" }
        end
      end
    end

    ##
    # Sends noop to each server to flush responses and ensure all writes complete.
    ##
    def finish_requests(servers)
      servers.each do |server|
        server.request(:noop)
      rescue DalliError, NetworkError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "unable to complete pipelined set on server #{server.name}" }
      end
    end

    def groups_for_keys(keys)
      validated_keys = keys.map { |k| @key_manager.validate_key(k.to_s) }
      groups = @ring.keys_grouped_by_server(validated_keys)

      if (unfound_keys = groups.delete(nil))
        Dalli.logger.debug do
          "unable to set #{unfound_keys.length} keys because no matching server was found"
        end
      end

      groups
    end
  end
end
