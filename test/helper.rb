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
end