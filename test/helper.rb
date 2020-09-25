# frozen_string_literal: true
$TESTING = true
require 'bundler/setup'
# require 'simplecov'
# SimpleCov.start
require 'minitest/pride' unless RUBY_ENGINE == 'rbx'
require 'minitest/autorun'
require 'mocha/minitest'
require_relative 'memcached_mock'

ENV['MEMCACHED_SASL_PWDB'] = "#{File.dirname(__FILE__)}/sasl/sasldb"
ENV['SASL_CONF_PATH'] = "#{File.dirname(__FILE__)}/sasl/memcached.conf"

require 'rails'
puts "Testing with Rails #{Rails.version}"

require 'dalli'
require 'logger'

require 'active_support/time'
require 'active_support/cache/dalli_store'

Dalli.logger = Logger.new(STDOUT)
Dalli.logger.level = Logger::ERROR

class MiniTest::Spec
  include MemcachedMock::Helper

  def assert_error(error, regexp=nil, &block)
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
