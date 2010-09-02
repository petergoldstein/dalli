require 'rubygems'
# require 'simplecov-html'
# SimpleCov.start

require 'test/unit'
require 'shoulda'
require 'memcached_mock'
require 'mocha'

require 'dalli'

class Test::Unit::TestCase
  include MemcachedMock::Helper

  def assert_error(error, regexp=nil, &block)
    ex = assert_raise(error, &block)
    assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
  end

  def with_activesupport
    case Rails.version
    when '3.0.0'
      require 'active_support/all'
    # when '2.3.0'
    #   require 'active_support'
    #   require 'active_support/cache/dalli_store23'
    end
    yield
  end

  def with_actionpack
    case Rails.version
    when '3.0.0'
      require 'action_dispatch'
      require 'action_controller'
    # when '2.3.0'
    #   raise NotImplementedError
    end
    yield
  end

end