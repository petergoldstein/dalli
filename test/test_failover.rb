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

    should 'handle them gracefully in get_multi' do
      memcached(29125) do
        memcached(29126) do
          dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
          dc.set 'a', 'a1'
          result = dc.get_multi ['a']
          assert_equal result, {'a' => 'a1'}
          
          memcached_kill(29125)

          result = dc.get_multi ['a']
          assert_equal result, {'a' => 'a1'}
        end
      end
    end

    should 'handle graceful failover in get_multi' do
      memcached(29125) do
        memcached(29126) do
          dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
          dc.set 'foo', 'foo1'
          dc.set 'bar', 'bar1'
          result = dc.get_multi ['foo', 'bar']
          assert_equal result, {'foo' => 'foo1', 'bar' => 'bar1'}
          
          memcached_kill(29125)

          dc.set 'foo', 'foo1'
          dc.set 'bar', 'bar1'
          result = dc.get_multi ['foo', 'bar']
          assert_equal result, {'foo' => 'foo1', 'bar' => 'bar1'}

          memcached_kill(29126)

          assert_raise Dalli::RingError, :message => "No server available" do
            dc.get_multi ['foo', 'bar']
          end
        end
      end
    end

    should 'stats should still properly report' do
      memcached(29125) do
        memcached(29126) do
          dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
          result = dc.stats
          assert_instance_of Hash, result['localhost:29125']
          assert_instance_of Hash, result['localhost:29126']
          
          memcached_kill(29125)

          dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
          result = dc.stats
          assert_instance_of NilClass, result['localhost:29125']
          assert_instance_of Hash, result['localhost:29126']

          memcached_kill(29126)
        end
      end
    end
  end
end
