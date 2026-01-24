# frozen_string_literal: true

require 'forwardable'
require 'socket'
require 'timeout'

module Dalli
  module Protocol
    ##
    # Access point for a single Memcached server, accessed via Memcached's meta
    # protocol.  Contains logic for managing connection state to the server (retries, etc),
    # formatting requests to the server, and unpacking responses.
    ##
    class Meta < Base
      TERMINATOR = "\r\n"

      def response_processor
        @response_processor ||= ResponseProcessor.new(@connection_manager, @value_marshaller)
      end

      # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

      private

      # Retrieval Commands
      def get(key, options = nil)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, base64: base64)
        write(req)
        response_processor.meta_get_with_value(cache_nils: cache_nils?(options))
      end

      def quiet_get_request(key)
        encoded_key, base64 = KeyRegularizer.encode(key)
        RequestFormatter.meta_get(key: encoded_key, return_cas: true, base64: base64, quiet: true)
      end

      def gat(key, ttl, options = nil)
        ttl = TtlSanitizer.sanitize(ttl)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, ttl: ttl, base64: base64)
        write(req)
        response_processor.meta_get_with_value(cache_nils: cache_nils?(options))
      end

      def touch(key, ttl)
        ttl = TtlSanitizer.sanitize(ttl)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, ttl: ttl, value: false, base64: base64)
        write(req)
        response_processor.meta_get_without_value
      end

      # TODO: This is confusing, as there's a cas command in memcached
      # and this isn't it.  Maybe rename?  Maybe eliminate?
      def cas(key)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, value: true, return_cas: true, base64: base64)
        write(req)
        response_processor.meta_get_with_value_and_cas
      end

      # Get with thundering herd protection using N (vivify) and R (recache) flags.
      # @note Requires memcached 1.6+ (meta protocol feature)
      #
      # @param key [String] the key to retrieve
      # @param recache_options [Hash] options for thundering herd protection
      #   - :vivify_ttl [Integer] creates a stub on miss with this TTL
      #   - :recache_ttl [Integer] wins recache race if remaining TTL is below this
      #   - :cache_nils [Boolean] whether to cache nil values
      # @return [Hash] containing :value, :cas, :won_recache, :stale, :lost_recache
      def get_with_recache(key, recache_options = {})
        vivify_ttl = recache_options[:vivify_ttl]
        recache_ttl = recache_options[:recache_ttl]

        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(
          key: encoded_key,
          value: true,
          return_cas: true,
          base64: base64,
          vivify_ttl: vivify_ttl,
          recache_ttl: recache_ttl
        )
        write(req)
        response_processor.meta_get_with_recache_status(cache_nils: cache_nils?(recache_options))
      end

      # Delete with stale invalidation instead of actual deletion.
      # Used with thundering herd protection to mark items as stale rather than removing them.
      # @note Requires memcached 1.6+ (meta protocol feature)
      #
      # @param key [String] the key to invalidate
      # @param cas [Integer] optional CAS value for compare-and-swap
      # @return [Boolean] true if successful
      def delete_stale(key, cas = nil)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_delete(key: encoded_key, cas: cas, base64: base64, stale: true)
        write(req)
        response_processor.meta_delete
      end

      # Storage Commands
      def set(key, value, ttl, cas, options)
        write_storage_req(:set, key, value, ttl, cas, options)
        response_processor.meta_set_with_cas unless quiet?
      end

      # Pipelined set - writes a quiet set request without reading response.
      # Used by PipelinedSetter for bulk operations.
      def pipelined_set(key, value, ttl, options)
        write_storage_req(:set, key, value, ttl, nil, options, quiet: true)
      end

      def add(key, value, ttl, options)
        write_storage_req(:add, key, value, ttl, nil, options)
        response_processor.meta_set_with_cas unless quiet?
      end

      def replace(key, value, ttl, cas, options)
        write_storage_req(:replace, key, value, ttl, cas, options)
        response_processor.meta_set_with_cas unless quiet?
      end

      # rubocop:disable Metrics/ParameterLists
      def write_storage_req(mode, key, raw_value, ttl = nil, cas = nil, options = {}, quiet: quiet?)
        (value, bitflags) = @value_marshaller.store(key, raw_value, options)
        ttl = TtlSanitizer.sanitize(ttl) if ttl
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_set(key: encoded_key, value: value,
                                        bitflags: bitflags, cas: cas,
                                        ttl: ttl, mode: mode, quiet: quiet, base64: base64)
        write(req)
        write(value)
        write(TERMINATOR)
      end
      # rubocop:enable Metrics/ParameterLists

      def append(key, value)
        write_append_prepend_req(:append, key, value)
        response_processor.meta_set_append_prepend unless quiet?
      end

      def prepend(key, value)
        write_append_prepend_req(:prepend, key, value)
        response_processor.meta_set_append_prepend unless quiet?
      end

      # rubocop:disable Metrics/ParameterLists
      def write_append_prepend_req(mode, key, value, ttl = nil, cas = nil, _options = {})
        ttl = TtlSanitizer.sanitize(ttl) if ttl
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_set(key: encoded_key, value: value, base64: base64,
                                        cas: cas, ttl: ttl, mode: mode, quiet: quiet?)
        write(req)
        write(value)
        write(TERMINATOR)
      end
      # rubocop:enable Metrics/ParameterLists

      # Delete Commands
      def delete(key, cas)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_delete(key: encoded_key, cas: cas,
                                           base64: base64, quiet: quiet?)
        write(req)
        response_processor.meta_delete unless quiet?
      end

      # Pipelined delete - writes a quiet delete request without reading response.
      # Used by PipelinedDeleter for bulk operations.
      def pipelined_delete(key)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_delete(key: encoded_key, base64: base64, quiet: true)
        write(req)
      end

      # Arithmetic Commands
      def decr(key, count, ttl, initial)
        decr_incr false, key, count, ttl, initial
      end

      def incr(key, count, ttl, initial)
        decr_incr true, key, count, ttl, initial
      end

      def decr_incr(incr, key, delta, ttl, initial)
        ttl = initial ? TtlSanitizer.sanitize(ttl) : nil # Only set a TTL if we want to set a value on miss
        encoded_key, base64 = KeyRegularizer.encode(key)
        write(RequestFormatter.meta_arithmetic(key: encoded_key, delta: delta, initial: initial, incr: incr, ttl: ttl,
                                               quiet: quiet?, base64: base64))
        response_processor.decr_incr unless quiet?
      end

      # Other Commands
      def flush(delay = 0)
        write(RequestFormatter.flush(delay: delay))
        response_processor.flush unless quiet?
      end

      # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
      # We need to read all the responses at once.
      def noop
        write_noop
        response_processor.consume_all_responses_until_mn
      end

      def stats(info = nil)
        write(RequestFormatter.stats(info))
        response_processor.stats
      end

      def reset_stats
        write(RequestFormatter.stats('reset'))
        response_processor.reset
      end

      def version
        write(RequestFormatter.version)
        response_processor.version
      end

      def write_noop
        write(RequestFormatter.meta_noop)
      end

      def authenticate_connection
        raise Dalli::DalliError, 'Authentication not supported for the meta protocol.'
      end

      require_relative 'meta/key_regularizer'
      require_relative 'meta/request_formatter'
      require_relative 'meta/response_processor'
    end
  end
end
