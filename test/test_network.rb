require 'helper'

class TestNetwork < Test::Unit::TestCase
  context 'assuming a bad network' do
    setup do
    end
    
    should 'handle connection refused' do
      assert_raises Dalli::NetworkError do
        dc = Dalli::Client.new 'localhost:19122'
        dc.get 'foo'
      end
    end

  end
end
