require 'helper'

describe 'failover' do

  describe 'timeouts' do
    it 'not lead to corrupt sockets' do
      memcached(29125) do
        dc = Dalli::Client.new ['localhost:29125']
        begin
          Timeout.timeout 0.01 do
            1_000.times do
              dc.set("test_123", {:test => "123"})
            end
            flunk("Did not timeout")
          end
        rescue Timeout::Error
        end

        assert_equal({:test => '123'}, dc.get("test_123"))
      end
    end
  end


  describe 'assuming some bad servers' do

    it 'silently reconnect if server hiccups' do
      memcached(29125) do
        dc = Dalli::Client.new ['localhost:29125']
        dc.set 'foo', 'bar'
        foo = dc.get 'foo'
        assert_equal foo, 'bar'

        memcached_kill(29125)
        memcached(29125) do

          foo = dc.get 'foo'
          assert_nil foo

          memcached_kill(29125)
        end
      end
    end

    it 'handle graceful failover' do
      memcached(29125) do
        memcached(29126) do
          dc = Dalli::Client.new ['localhost:29125', 'localhost:29126']
          dc.set 'foo', 'bar'
          foo = dc.get 'foo'
          assert_equal foo, 'bar'

          memcached_kill(29125)

          dc.set 'foo', 'bar'
          foo = dc.get 'foo'
          assert_equal foo, 'bar'

          memcached_kill(29126)

          assert_raises Dalli::RingError, :message => "No server available" do
            dc.set 'foo', 'bar'
          end
        end
      end
    end

    it 'handle them gracefully in get_multi' do
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

    it 'handle graceful failover in get_multi' do
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

          result = dc.get_multi ['foo', 'bar']
          assert_equal result, {}
        end
      end
    end

    it 'stats it still properly report' do
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
