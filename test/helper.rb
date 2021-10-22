# frozen_string_literal: true

$TESTING = true
require "bundler/setup"
# require 'simplecov'
# SimpleCov.start
require "minitest/pride"
require "minitest/autorun"
require_relative "helpers/memcached"

ENV["MEMCACHED_SASL_PWDB"] = "#{File.dirname(__FILE__)}/sasl/sasldb"
ENV["SASL_CONF_PATH"] = "#{File.dirname(__FILE__)}/sasl/memcached.conf"

require "dalli"
require "logger"
require 'securerandom'

Dalli.logger = Logger.new($stdout)
Dalli.logger.level = Logger::ERROR

class MiniTest::Spec
  include Memcached::Helper

  def assert_error(error, regexp = nil, &block)
    ex = assert_raises(error, &block)
    assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
  end

  def op_cas_succeeds(rsp)
    rsp.is_a?(Integer) && rsp > 0
  end

  def op_replace_succeeds(rsp)
    rsp.is_a?(Integer) && rsp > 0
  end

  # add and set must have the same return value because of DalliStore#write_entry
  def op_addset_succeeds(rsp)
    rsp.is_a?(Integer) && rsp > 0
  end

  def with_connectionpool
    require "connection_pool"
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
