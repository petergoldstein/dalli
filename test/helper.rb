require 'rubygems'
require 'test/unit'
require 'shoulda'

require 'dalli'

class Test::Unit::TestCase
  def assert_error(error, regexp=nil)
    begin
      yield
      fail("Expected #{error.name} but nothing was raised.")
    rescue error => err
      fail("Expected error to match #{regexp.inspect}: #{err.inspect}") if regexp and err.message !~ regexp
      # success
    rescue Exception => ex
      fail("Expected #{error.name} but got #{ex.class.name}")
    end
  end
end