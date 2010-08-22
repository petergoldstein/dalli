require 'helper'
require 'memcached_mock'

class TestDalli < Test::Unit::TestCase
  context 'using a live server' do

    should "support huge get/set" do
      memcached do
        dc = Dalli::Client.new('localhost:19122')
        dc.flush

        val1 = "1234567890"*105000
        assert_error Dalli::DalliError, /too large/ do
          dc.set('a', val1)
          val2 = dc.get('a')
          assert_equal val1, val2
        end

        val1 = "1234567890"*100000
        dc.set('a', val1)
        val2 = dc.get('a')
        assert_equal val1, val2
      end
    end

    should "support the fetch operation" do
      memcached do
        dc = Dalli::Client.new(['localhost:19122', '127.0.0.1:19122'])
        dc.flush

        expected = { 'blah' => 'blerg!' }
        executed = false
        value = dc.fetch('fetch_key') do
          executed = true
          expected
        end
        assert_equal expected, value
        assert_equal true, executed

        executed = false
        value = dc.fetch('fetch_key') do
          executed = true
          expected
        end
        assert_equal expected, value
        assert_equal false, executed
      end
    end

    should "support the cas operation" do
      memcached do
        dc = Dalli::Client.new(['localhost:19122', '127.0.0.1:19122'])
        dc.flush

        expected = { 'blah' => 'blerg!' }

        resp = dc.cas('cas_key') do |value|
          fail('Value should not exist')
        end
        assert_nil resp

        mutated = { 'blah' => 'foo!' }
        dc.set('cas_key', expected)
        resp = dc.cas('cas_key') do |value|
          assert_equal expected, value
          mutated
        end
        assert_equal true, resp
        
        resp = dc.get('cas_key')
        assert_equal mutated, resp
        
        # TODO Need to verify failure when value is mutated between get and add.
      end
    end

    should "support multi-get" do
      memcached do
        dc = Dalli::Client.new(['localhost:19122', '127.0.0.1:19122'])
        dc.flush
        resp = dc.get_multi(%w(a b c d e f))
        assert_equal({}, resp)

        dc.set('a', 'foo')
        dc.set('b', 123)
        dc.set('c', %w(a b c))
        resp = dc.get_multi(%w(a b c d e f))
        assert_equal({ 'a' => 'foo', 'b' => 123, 'c' => %w(a b c) }, resp)
      end
    end

    should "support incr/decr operations" do
      memcached do
        dc = Dalli::Client.new(['localhost:19122', '127.0.0.1:19122'])
        dc.flush

        resp = dc.decr('counter', 100, 5, 0)
        assert_equal 0, resp

        resp = dc.decr('counter', 10)
        assert_equal 0, resp

        resp = dc.incr('counter', 10)
        assert_equal 10, resp

        # go over the 32-bit mark to verify proper (un)packing
        resp = dc.incr('counter', 10_000_000_000)
        assert_equal 10_000_000_010, resp

        resp = dc.decr('counter', 1)
        assert_equal 10_000_000_009, resp

        resp = dc.decr('counter', 0)
        assert_equal 10_000_000_009, resp

        resp = dc.incr('counter', 0)
        assert_equal 10_000_000_009, resp

        assert_nil dc.incr('DNE', 10)
        assert_nil dc.decr('DNE', 10)

        resp = dc.incr('big', 100, 5, 0xFFFFFFFFFFFFFFFE)
        assert_equal 0xFFFFFFFFFFFFFFFE, resp
        resp = dc.incr('big', 1)
        assert_equal 0xFFFFFFFFFFFFFFFF, resp

        # rollover the 64-bit value, we'll get something undefined.
        resp = dc.incr('big', 1)
        assert_not_equal 0x10000000000000000, resp
      end
    end

    should "pass a simple smoke test" do
      memcached do      
        dc = Dalli::Client.new('localhost:19122')
        resp = dc.flush
        assert_not_nil resp
        assert_equal [true], resp

        resp = dc.get('123')
        assert_equal nil, resp

        resp = dc.set('123', 'xyz')
        assert_equal true, resp

        resp = dc.get('123')
        assert_equal 'xyz', resp

        resp = dc.set('123', 'abc')
        assert_equal true, resp

        assert_raises Dalli::DalliError do
          dc.prepend('123', '0')
        end

        assert_raises Dalli::DalliError do
          dc.append('123', '0')
        end

        resp = dc.get('123')
        assert_equal 'abc', resp
        dc.close
        dc = nil

        dc = Dalli::Client.new('localhost:19122', :marshal => false)

        resp = dc.set('456', 'xyz')
        assert_equal true, resp

        resp = dc.prepend '456', '0'
        assert_equal true, resp

        resp = dc.append '456', '9'
        assert_equal true, resp

        resp = dc.get('456')
        assert_equal '0xyz9', resp

        resp = dc.stats
        assert_equal Hash, resp.class
      end
    end

  end
end
