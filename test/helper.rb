# frozen_string_literal: true

require_relative 'support/strict_warnings'

require 'bundler/setup'
# require 'simplecov'
# SimpleCov.start
require 'minitest/pride'
require 'minitest/autorun'
require 'minitest/mock'
require_relative 'helpers/memcached'

require 'dalli'
require 'logger'
require 'securerandom'

Dalli.logger = Logger.new($stdout)
Dalli.logger.level = Logger::ERROR

# Checks if memcached is installed and loads the version,
# supported protocols
raise StandardError, 'No supported version of memcached could be found.' unless MemcachedManager.version

# Generate self-signed certs for SSL once per suite run.
CertificateGenerator.generate

module Minitest
  class Spec
    include Memcached::Helper

    def assert_error(error, regexp = nil, &)
      ex = assert_raises(error, &)

      assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
    end

    def valid_cas?(cas)
      cas.is_a?(Integer) && cas.positive?
    end

    def op_cas_succeeds(rsp)
      valid_cas?(rsp)
    end

    def op_replace_succeeds(rsp)
      valid_cas?(rsp)
    end

    # add and set must have the same return value because of DalliStore#write_entry
    def op_addset_succeeds(rsp)
      valid_cas?(rsp)
    end

    def with_connectionpool
      require 'connection_pool'
      yield
    end

    def with_nil_logger
      old = Dalli.logger
      Dalli.logger = Logger.new(nil)
      begin
        yield
      ensure
        Dalli.logger = old
      end
    end

    # Each multi-get, as a lambda returning { key => value }. The block forms
    # fail on a key yielded twice.
    MULTI_GETS = {
      'get_multi' => ->(dc, keys) { dc.get_multi(keys) },
      'get_multi with a block' => lambda do |dc, keys|
        collect_yields { |results| dc.get_multi(keys) { |k, v| results << [k, v] } }
      end,
      'get_multi_cas' => ->(dc, keys) { dc.get_multi_cas(keys).transform_values(&:first) },
      'get_multi_cas with a block' => lambda do |dc, keys|
        collect_yields { |results| dc.get_multi_cas(keys) { |k, (v, _)| results << [k, v] } }
      end,
      'get_multi_with_metadata' => ->(dc, keys) { dc.get_multi_with_metadata(keys).transform_values { _1[:value] } },
      'get_multi_with_metadata with a block' => lambda do |dc, keys|
        collect_yields { |results| dc.get_multi_with_metadata(keys) { |k, meta| results << [k, meta[:value]] } }
      end
    }.freeze

    def self.collect_yields
      results = []
      yield results
      if results.uniq(&:first) != results
        raise Minitest::Assertion, "a key was yielded more than once: #{results.inspect}"
      end

      results.to_h
    end

    # Yields a single-server client, then a two-server one, both with options.
    # Each is closed afterwards, so a Ruby that closes sockets only on GC
    # doesn't run memcached out of connections.
    def with_one_and_two_servers(protocol, **options, &)
      memcached_persistent(protocol, 21_345) do |_, port1|
        with_closed_client("localhost:#{port1}", options, &)
        memcached_persistent(protocol, 21_346) do |_, port2|
          with_closed_client(["localhost:#{port1}", "localhost:#{port2}"], options, &)
        end
      end
    end

    def with_closed_client(servers, options)
      dc = Dalli::Client.new(servers, options)
      yield dc
    ensure
      dc&.close
    end

    # A multi-get's results are returned under the caller's keys: equal, and
    # with the same encoding, so result.key?(key) holds for a binary key too
    def assert_caller_keys(expected, result)
      assert_equal expected, result
      expected.each_key do |key|
        assert result.key?(key), "#{key.inspect} missing from #{result.keys.inspect}"
        assert_equal key.encoding, result.keys.find { _1 == key }.encoding
      end
    end
  end
end
