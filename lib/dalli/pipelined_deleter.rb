# frozen_string_literal: true

module Dalli
  ##
  # Contains logic for the pipelined delete operations implemented by the client.
  # Efficiently deletes multiple keys by grouping requests by server
  # and using quiet mode to minimize round trips.
  ##
  class PipelinedDeleter
    def initialize(ring, key_manager)
      @ring = ring
      @key_manager = key_manager
    end

    ##
    # Deletes multiple keys from memcached.
    #
    # @param keys [Array<String>] keys to delete
    # @return [void]
    ##
    def process(keys)
      return if keys.empty?

      @ring.lock do
        servers = setup_requests(keys)
        finish_requests(servers)
      end
    rescue NetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined deletes because of network error' }
      retry
    end

    private

    def setup_requests(keys)
      groups = groups_for_keys(keys)
      make_delete_requests(groups)
      groups.keys
    end

    ##
    # Loop through the server-grouped sets of keys, writing
    # the corresponding quiet delete requests to the appropriate servers
    ##
    def make_delete_requests(groups)
      groups.each do |server, keys_for_server|
        keys_for_server.each do |key|
          server.request(:pipelined_delete, key)
        rescue DalliError, NetworkError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "unable to delete key #{key} for server #{server.name}" }
        end
      end
    end

    ##
    # Sends noop to each server to flush responses and ensure all deletes complete.
    ##
    def finish_requests(servers)
      servers.each do |server|
        server.request(:noop)
      rescue DalliError, NetworkError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "unable to complete pipelined delete on server #{server.name}" }
      end
    end

    def groups_for_keys(keys)
      validated_keys = keys.map { |k| @key_manager.validate_key(k.to_s) }
      groups = @ring.keys_grouped_by_server(validated_keys)

      if (unfound_keys = groups.delete(nil))
        Dalli.logger.debug do
          "unable to delete #{unfound_keys.length} keys because no matching server was found"
        end
      end

      groups
    end
  end
end
