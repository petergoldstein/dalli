$TESTING = true
require 'rubygems'
# require 'simplecov'
# SimpleCov.start
require 'minitest/pride'
require 'minitest/autorun'
require 'mocha/setup'
require 'memcached_mock'

WANT_RAILS_VERSION = ENV['RAILS_VERSION'] || '>= 3.0.0'
gem 'rails', WANT_RAILS_VERSION
require 'rails'
puts "Testing with Rails #{Rails.version}"

require 'dalli'
require 'logger'

Dalli.logger = Logger.new(STDOUT)
Dalli.logger.level = Logger::ERROR

class MiniTest::Spec
  include MemcachedMock::Helper

  def assert_error(error, regexp=nil, &block)
    ex = assert_raises(error, &block)
    assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
  end

  def with_activesupport
    require 'active_support/all'
    require 'active_support/cache/dalli_store'
    yield
  end

  def with_actionpack
    require 'action_dispatch'
    require 'action_controller'
    yield
  end
end
