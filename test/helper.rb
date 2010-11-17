$TESTING = true
require 'rubygems'
# require 'simplecov'
# SimpleCov.start
RAILS_VERSION = ENV['RAILS_VERSION'] || '~> 3.0.0'
#puts "Testing with Rails #{RAILS_VERSION}"
gem 'rails', RAILS_VERSION

require 'test/unit'
require 'shoulda'
require 'memcached_mock'
require 'mocha'

require 'dalli'
require 'logger'

Dalli.logger = Logger.new(STDOUT)
Dalli.logger.level = Logger::ERROR

class Test::Unit::TestCase
  include MemcachedMock::Helper

  def rails3?
    RAILS_VERSION =~ /3\.0\./
  end

  def assert_error(error, regexp=nil, &block)
    ex = assert_raise(error, &block)
    assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
  end

  def with_activesupport
    case 
    when rails3?
      require 'active_support/all'
    else
      require 'active_support'
      require 'active_support/cache/dalli_store23'
    end
    yield
  end

  def with_actionpack
    case
    when rails3?
      require 'action_dispatch'
      require 'action_controller'
    # when '2.3.0'
    #   raise NotImplementedError
    end
    yield
  end

end
