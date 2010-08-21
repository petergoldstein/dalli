require 'rubygems'
require 'test/unit'
require 'shoulda'

require 'dalli'

class Test::Unit::TestCase
  def assert_error(error, regexp=nil, &block)
    ex = assert_raise(error, &block)
    assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
  end
end