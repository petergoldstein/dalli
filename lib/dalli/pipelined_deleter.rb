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
    # @return [Integer] the number of keys that were deleted. This is
    #   best-effort: on a network error the operation is retried, and keys
    #   deleted before the error are not recounted, so the result may
    #   under-report the number actually removed when a failure occurs.
    ##
    def process(keys)
      return 0 if keys.empty?

      @ring.lock do
        groups = setup_requests(keys)
        finish_requests(groups)
      end
    rescue Dalli::RetryableNetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying pipelined deletes because of network error' }
      retry
    end

    private

    def setup_requests(keys)
      groups = groups_for_keys(keys)
      make_delete_requests(groups)
      groups
    end

    ##
    # Loop through the server-grouped sets of keys, writing
    # the corresponding quiet delete requests to the appropriate servers
    ##
    # NetworkError (which RetryableNetworkError subclasses) must propagate: the
    # top-level rescue in #process retries the whole pipelined delete on it. A
    # combined `rescue DalliError, NetworkError` would silently swallow
    # RetryableNetworkError too -- since NetworkError < DalliError -- dropping
    # this server's keys on a transient hiccup instead of retrying. Only a
    # non-network DalliError should be swallowed here.
    def make_delete_requests(groups)
      groups.each do |server, keys_for_server|
        keys_for_server.select! do |key|
          server.request(:pipelined_delete, key)
          true
        rescue Dalli::NetworkError
          raise
        rescue DalliError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "unable to delete key #{key} for server #{server.name}" }
          false
        end
      end
    end

    ##
    # Sends noop to each server to flush responses and ensure all deletes complete.
    # Returns the total successful deletes across servers.
    ##
    def finish_requests(groups)
      groups.sum do |server, keys_for_server|
        server.request(:finish_pipelined_delete, keys_for_server.size)
      rescue Dalli::NetworkError
        raise
      rescue DalliError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "unable to complete pipelined delete on server #{server.name}" }
        0
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
