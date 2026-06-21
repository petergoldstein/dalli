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
        # Skip bitflags in raw mode - saves 2 bytes per request and skips parsing
        skip_flags = raw_mode? || (options && options[:raw])
        req = RequestFormatter.meta_get(key: key, skip_flags: skip_flags)
        flushed_write(req)
        response_processor.meta_get_with_value(cache_nils: cache_nils?(options))
      end

      def quiet_get_request(key)
        # Skip bitflags in raw mode - saves 2 bytes per request and skips parsing
        RequestFormatter.meta_get(key: key, return_cas: true, quiet: true, skip_flags: raw_mode?)
      end

      def gat(key, ttl, options = nil)
        ttl = TtlSanitizer.sanitize(ttl)
        skip_flags = raw_mode? || (options && options[:raw])
        req = RequestFormatter.meta_get(key: key, ttl: ttl, skip_flags: skip_flags)
        flushed_write(req)
        response_processor.meta_get_with_value(cache_nils: cache_nils?(options))
      end

      def touch(key, ttl)
        ttl = TtlSanitizer.sanitize(ttl)
        req = RequestFormatter.meta_get(key: key, ttl: ttl, value: false)
        flushed_write(req)
        response_processor.meta_get_without_value
      end

      # TODO: This is confusing, as there's a cas command in memcached
      # and this isn't it.  Maybe rename?  Maybe eliminate?
      def cas(key)
        req = RequestFormatter.meta_get(key: key, value: true, return_cas: true)
        flushed_write(req)
        response_processor.meta_get_with_value_and_cas
      end

      # Comprehensive meta get with support for all metadata flags.
      # @note Requires memcached 1.6+ (meta protocol feature)
      #
      # This is the full-featured get method that supports:
      # - Thundering herd protection (vivify_ttl, recache_ttl)
      # - Item metadata (hit_status, last_access)
      # - LRU control (skip_lru_bump)
      #
      # @param key [String] the key to retrieve
      # @param options [Hash] options controlling what metadata to return
      #   - :vivify_ttl [Integer] creates a stub on miss with this TTL (N flag)
      #   - :recache_ttl [Integer] wins recache race if remaining TTL is below this (R flag)
      #   - :return_hit_status [Boolean] return whether item was previously accessed (h flag)
      #   - :return_last_access [Boolean] return seconds since last access (l flag)
      #   - :skip_lru_bump [Boolean] don't bump LRU or update access stats (u flag)
      #   - :cache_nils [Boolean] whether to cache nil values
      # @return [Hash] containing:
      #   - :value - the cached value (or nil on miss)
      #   - :cas - the CAS value
      #   - :won_recache - true if client won recache race (W flag)
      #   - :stale - true if item is stale (X flag)
      #   - :lost_recache - true if another client is recaching (Z flag)
      #   - :hit_before - true/false if previously accessed (only if return_hit_status: true)
      #   - :last_access - seconds since last access (only if return_last_access: true)
      def meta_get(key, options = {})
        req = RequestFormatter.meta_get(
          key: key, value: true, return_cas: true,
          vivify_ttl: options[:vivify_ttl], recache_ttl: options[:recache_ttl],
          return_hit_status: options[:return_hit_status],
          return_last_access: options[:return_last_access], skip_lru_bump: options[:skip_lru_bump]
        )
        flushed_write(req)
        response_processor.meta_get_with_metadata(
          cache_nils: cache_nils?(options), return_hit_status: options[:return_hit_status],
          return_last_access: options[:return_last_access]
        )
      end

      # Delete with stale invalidation instead of actual deletion.
      # Used with thundering herd protection to mark items as stale rather than removing them.
      # @note Requires memcached 1.6+ (meta protocol feature)
      #
      # @param key [String] the key to invalidate
      # @param cas [Integer] optional CAS value for compare-and-swap
      # @return [Boolean] true if successful
      def delete_stale(key, cas = nil)
        req = RequestFormatter.meta_delete(key: key, cas: cas, stale: true)
        flushed_write(req)
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
        req = RequestFormatter.meta_set(key: key, value: value,
                                        bitflags: bitflags, cas: cas,
                                        ttl: ttl, mode: mode, quiet: quiet)
        write("#{req}#{value}#{TERMINATOR}")
        @connection_manager.flush unless quiet
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
        req = RequestFormatter.meta_set(key: key, value: value,
                                        cas: cas, ttl: ttl, mode: mode, quiet: quiet?)
        write("#{req}#{value}#{TERMINATOR}")
        @connection_manager.flush unless quiet?
      end
      # rubocop:enable Metrics/ParameterLists

      # Delete Commands
      def delete(key, cas)
        req = RequestFormatter.meta_delete(key: key, cas: cas, quiet: quiet?)
        write(req)
        @connection_manager.flush unless quiet?
        response_processor.meta_delete unless quiet?
      end

      # Pipelined delete - writes a quiet delete request without reading response.
      # Used by PipelinedDeleter for bulk operations.
      def pipelined_delete(key)
        req = RequestFormatter.meta_delete(key: key, quiet: true)
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
        write(RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial, incr: incr, ttl: ttl,
                                               quiet: quiet?))
        @connection_manager.flush unless quiet?
        response_processor.decr_incr unless quiet?
      end

      # Other Commands
      def flush(delay = 0)
        write(RequestFormatter.flush(delay: delay))
        @connection_manager.flush unless quiet?
        response_processor.flush unless quiet?
      end

      # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
      # We need to read all the responses at once.
      def noop
        write_noop
        response_processor.consume_all_responses_until_mn
      end

      def stats(info = nil)
        flushed_write(RequestFormatter.stats(info))
        response_processor.stats
      end

      def reset_stats
        flushed_write(RequestFormatter.stats('reset'))
        response_processor.reset
      end

      def version
        flushed_write(RequestFormatter.version)
        response_processor.version
      end

      def write_noop
        flushed_write(RequestFormatter.meta_noop)
      end

      # Single-server fast path for get_multi. Inlines request formatting and
      # response parsing to minimize per-key overhead. Avoids the PipelinedGetter
      # machinery (IO.select, response buffering, server grouping).
      def read_multi_req(keys)
        is_raw = raw_mode?
        buffer = RequestFormatter.multi_meta_get(keys, skip_flags: is_raw)
        flushed_write(buffer)
        buffer.clear
        read_multi_get_responses(is_raw)
      end

      def read_multi_get_responses(is_raw)
        hash = {}
        key_index = is_raw ? 2 : 3
        while (line = @connection_manager.read_line)
          break if line.start_with?('MN')
          next unless line.start_with?('VA ')

          key, value = parse_multi_get_value(line, key_index, is_raw)
          hash[key] = value if key
        end
        hash
      end

      def parse_multi_get_value(line, key_index, is_raw)
        tokens = line.chomp!(TERMINATOR).split
        value = @connection_manager.read(tokens[1].to_i + TERMINATOR.bytesize)&.chomp!(TERMINATOR)
        raw_key = tokens[key_index]
        return unless raw_key

        key = raw_key[1..]
        key = KeyRegularizer.decode(key) if tokens.include?('b')
        bitflags = is_raw ? 0 : response_processor.bitflags_from_tokens(tokens)
        [key, @value_marshaller.retrieve(value, bitflags)]
      end

      # Single-server fast path for set_multi. Inlines request formatting to
      # minimize per-key overhead. Avoids PipelinedSetter server grouping.
      def write_multi_req(pairs, ttl, req_options)
        ttl = TtlSanitizer.sanitize(ttl) if ttl
        entries = pairs.map do |key, raw_value|
          [key, @value_marshaller.store(key, raw_value, req_options)]
        end

        buffer = RequestFormatter.multi_meta_set(entries, ttl: ttl)
        flushed_write(buffer)
        buffer.clear
        response_processor.consume_all_responses_until_mn
      end

      # Single-server fast path for delete_multi. Writes all quiet delete requests
      # terminated by a noop, then consumes all responses.
      def delete_multi_req(keys)
        buffer = RequestFormatter.multi_meta_delete(keys)
        flushed_write(buffer)
        buffer.clear
        response_processor.consume_all_responses_until_mn
      end

      require_relative 'key_regularizer'
      require_relative 'request_formatter'
      require_relative 'response_processor'
    end
  end
end
