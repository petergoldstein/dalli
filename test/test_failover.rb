require 'helper'

class TestFailover < Test::Unit::TestCase
  context 'assuming some bad servers' do
    should 'handle graceful failover' do
      memcached(29125) do
        memcached(29126) do
          dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
          dc.set 'foo', 'bar'
          foo = dc.get 'foo'
          assert foo, 'bar'
          
          memcached_kill(29125)

          dc.set 'foo', 'bar'
          foo = dc.get 'foo'
          assert foo, 'bar'

          memcached_kill(29126)

          assert_raise Dalli::RingError, :message => "No server available" do
            dc.set 'foo', 'bar'
          end
        end
      end
    end
  end
end
