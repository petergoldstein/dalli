# frozen_string_literal: true

require 'bundler/setup'
# require 'simplecov'
# SimpleCov.start
require 'minitest/pride'
require 'minitest/autorun'
require_relative 'helpers/memcached'

ENV['SASL_CONF_PATH'] = "#{File.dirname(__FILE__)}/sasl/memcached.conf"

require 'dalli'
require 'logger'
require 'ostruct'
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

    def assert_error(error, regexp = nil, &block)
      ex = assert_raises(error, &block)

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
  end
end
