# frozen_string_literal: true

require 'forwardable'
require 'socket'
require 'timeout'

module Dalli
  module Protocol
    ##
    # Access point for a single Memcached server, accessed via Memcached's binary
    # protocol.  Contains logic for managing connection state to the server (retries, etc),
    # formatting requests to the server, and unpacking responses.
    ##
    class Binary < Base
      def response_processor
        @response_processor ||= ResponseProcessor.new(@connection_manager, @value_marshaller)
      end

      private

      # Retrieval Commands
      def get(key, options = nil)
        req = RequestFormatter.standard_request(opkey: :get, key: key)
        write(req)
        response_processor.get(cache_nils: cache_nils?(options))
      end

      def quiet_get_request(key)
        RequestFormatter.standard_request(opkey: :getkq, key: key)
      end

      def gat(key, ttl, options = nil)
        ttl = TtlSanitizer.sanitize(ttl)
        req = RequestFormatter.standard_request(opkey: :gat, key: key, ttl: ttl)
        write(req)
        response_processor.get(cache_nils: cache_nils?(options))
      end

      def touch(key, ttl)
        ttl = TtlSanitizer.sanitize(ttl)
        write(RequestFormatter.standard_request(opkey: :touch, key: key, ttl: ttl))
        response_processor.generic_response
      end

      # TODO: This is confusing, as there's a cas command in memcached
      # and this isn't it.  Maybe rename?  Maybe eliminate?
      def cas(key)
        req = RequestFormatter.standard_request(opkey: :get, key: key)
        write(req)
        response_processor.data_cas_response
      end

      # Storage Commands
      def set(key, value, ttl, cas, options)
        opkey = quiet? ? :setq : :set
        storage_req(opkey, key, value, ttl, cas, options)
      end

      def add(key, value, ttl, options)
        opkey = quiet? ? :addq : :add
        storage_req(opkey, key, value, ttl, 0, options)
      end

      def replace(key, value, ttl, cas, options)
        opkey = quiet? ? :replaceq : :replace
        storage_req(opkey, key, value, ttl, cas, options)
      end

      # rubocop:disable Metrics/ParameterLists
      def storage_req(opkey, key, value, ttl, cas, options)
        (value, bitflags) = @value_marshaller.store(key, value, options)
        ttl = TtlSanitizer.sanitize(ttl)

        req = RequestFormatter.standard_request(opkey: opkey, key: key,
                                                value: value, bitflags: bitflags,
                                                ttl: ttl, cas: cas)
        write(req)
        response_processor.storage_response unless quiet?
      end
      # rubocop:enable Metrics/ParameterLists

      def append(key, value)
        opkey = quiet? ? :appendq : :append
        write_append_prepend opkey, key, value
      end

      def prepend(key, value)
        opkey = quiet? ? :prependq : :prepend
        write_append_prepend opkey, key, value
      end

      def write_append_prepend(opkey, key, value)
        write(RequestFormatter.standard_request(opkey: opkey, key: key, value: value))
        response_processor.no_body_response unless quiet?
      end

      # Delete Commands
      def delete(key, cas)
        opkey = quiet? ? :deleteq : :delete
        req = RequestFormatter.standard_request(opkey: opkey, key: key, cas: cas)
        write(req)
        response_processor.delete unless quiet?
      end

      # Arithmetic Commands
      def decr(key, count, ttl, initial)
        opkey = quiet? ? :decrq : :decr
        decr_incr opkey, key, count, ttl, initial
      end

      def incr(key, count, ttl, initial)
        opkey = quiet? ? :incrq : :incr
        decr_incr opkey, key, count, ttl, initial
      end

      # This allows us to special case a nil initial value, and
      # handle it differently than a zero.  This special value
      # for expiry causes memcached to return a not found
      # if the key doesn't already exist, rather than
      # setting the initial value
      NOT_FOUND_EXPIRY = 0xFFFFFFFF

      def decr_incr(opkey, key, count, ttl, initial)
        expiry = initial ? TtlSanitizer.sanitize(ttl) : NOT_FOUND_EXPIRY
        initial ||= 0
        write(RequestFormatter.decr_incr_request(opkey: opkey, key: key,
                                                 count: count, initial: initial, expiry: expiry))
        response_processor.decr_incr unless quiet?
      end

      # Other Commands
      def flush(ttl = 0)
        opkey = quiet? ? :flushq : :flush
        write(RequestFormatter.standard_request(opkey: opkey, ttl: ttl))
        response_processor.no_body_response unless quiet?
      end

      # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
      # We need to read all the responses at once.
      def noop
        write_noop
        response_processor.consume_all_responses_until_noop
      end

      def stats(info = '')
        req = RequestFormatter.standard_request(opkey: :stat, key: info)
        write(req)
        response_processor.stats
      end

      def reset_stats
        write(RequestFormatter.standard_request(opkey: :stat, key: 'reset'))
        response_processor.reset
      end

      def version
        write(RequestFormatter.standard_request(opkey: :version))
        response_processor.version
      end

      def write_noop
        req = RequestFormatter.standard_request(opkey: :noop)
        write(req)
      end

      require_relative 'binary/request_formatter'
      require_relative 'binary/response_header'
      require_relative 'binary/response_processor'
      require_relative 'binary/sasl_authentication'
      include SaslAuthentication
    end
  end
end
