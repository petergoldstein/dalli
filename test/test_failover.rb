require 'helper'

class TestFailover < Test::Unit::TestCase

  context 'assuming some bad servers' do

    should 'handle graceful failover' do
      memcached(29125) do
        dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
        dc.set 'foo', 'bar'
        foo = dc.get 'foo'
        assert foo, 'bar'
      end
    end

  end
end
