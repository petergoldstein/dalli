require 'helper'
require 'memcached_mock'

class TestDalli < Test::Unit::TestCase

  should "default to localhost:11211" do
    dc = Dalli::Client.new
    ring = dc.send(:ring)
    s1 = ring.servers.first.hostname
    assert_equal 1, ring.servers.size
    dc.close

    dc = Dalli::Client.new('localhost:11211')
    ring = dc.send(:ring)
    s2 = ring.servers.first.hostname
    assert_equal 1, ring.servers.size
    dc.close

    dc = Dalli::Client.new(['localhost:11211'])
    ring = dc.send(:ring)
    s3 = ring.servers.first.hostname
    assert_equal 1, ring.servers.size
    dc.close

    assert_equal s1, s2
    assert_equal s2, s3
  end

  should "have the continuum sorted by value" do
    servers = [stub(:hostname => "localhost", :port => "11211", :weight => 1),
               stub(:hostname => "localhost", :port => "9500", :weight => 1)]
    ring = Dalli::Ring.new(servers, {})
    previous_value = 0
    ring.continuum.each do |entry|
      assert entry.value > previous_value
      previous_value = entry.value
    end
  end

  context 'using a live server' do

    should "support get/set" do
      memcached do |dc|
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
        
        assert_equal true, dc.set('a', nil)
        assert_nil dc.get('a')
      end
    end

    should "support the fetch operation" do
      memcached do |dc|
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
      memcached do |dc|
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
      memcached do |dc|
        dc.close
        dc.flush
        resp = dc.get_multi(%w(a b c d e f))
        assert_equal({}, resp)

        dc.set('a', 'foo')
        dc.set('b', 123)
        dc.set('c', %w(a b c))
        resp = dc.get_multi(%w(a b c d e f))
        assert_equal({ 'a' => 'foo', 'b' => 123, 'c' => %w(a b c) }, resp)

        # Perform a huge multi-get with 10,000 elements.
        arr = []
        dc.multi do
          10_000.times do |idx|
            dc.set idx, idx
            arr << idx
          end
        end

        result = dc.get_multi(arr)
        assert_equal(10_000, result.size)
        assert_equal(1000, result['1000'])
      end
    end

    should 'support raw incr/decr' do
      memcached do |client|
        client.flush

        assert_equal true, client.set('fakecounter', 0, 0, :raw => true)
        assert_equal 1, client.incr('fakecounter', 1)
        assert_equal 2, client.incr('fakecounter', 1)
        assert_equal 3, client.incr('fakecounter', 1)
        assert_equal 1, client.decr('fakecounter', 2)
        assert_equal "1", client.get('fakecounter', :raw => true)

        resp = client.incr('mycounter', 0)
        assert_nil resp

        resp = client.incr('mycounter', 1, 0, 2)
        assert_equal 2, resp
        resp = client.incr('mycounter', 1)
        assert_equal 3, resp

        resp = client.set('rawcounter', 10, 0, :raw => true)
        assert_equal true, resp

        resp = client.get('rawcounter', :raw => true)
        assert_equal '10', resp

        resp = client.incr('rawcounter', 1)
        assert_equal 11, resp
      end
    end

    should "support incr/decr operations" do
      memcached do |dc|
        dc.flush

        resp = dc.decr('counter', 100, 5, 0)
        assert_equal 0, resp

        resp = dc.decr('counter', 10)
        assert_equal 0, resp

        resp = dc.incr('counter', 10)
        assert_equal 10, resp

        current = 10
        100.times do |x|
          resp = dc.incr('counter', 10)
          assert_equal current + ((x+1)*10), resp
        end

        resp = dc.decr('10billion', 0, 5, 10)
        # go over the 32-bit mark to verify proper (un)packing
        resp = dc.incr('10billion', 10_000_000_000)
        assert_equal 10_000_000_010, resp

        resp = dc.decr('10billion', 1)
        assert_equal 10_000_000_009, resp

        resp = dc.decr('10billion', 0)
        assert_equal 10_000_000_009, resp

        resp = dc.incr('10billion', 0)
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
        dc.reset
      end
    end

    should 'support the append and prepend operations' do
      memcached do |dc|
        resp = dc.flush
        assert_equal true, dc.set('456', 'xyz', 0, :raw => true)
        assert_equal true, dc.prepend('456', '0')
        assert_equal true, dc.append('456', '9')
        assert_equal '0xyz9', dc.get('456', :raw => true)

        assert_raises Dalli::DalliError do
          assert_equal '0xyz9', dc.get('456')
        end

        assert_equal false, dc.append('nonexist', 'abc')
        assert_equal false, dc.prepend('nonexist', 'abc')
      end
    end

    should "pass a simple smoke test" do
      memcached do |dc|
        resp = dc.flush
        assert_not_nil resp
        assert_equal [true, true], resp

        assert_equal true, dc.set(:foo, 'bar')
        assert_equal 'bar', dc.get(:foo)

        resp = dc.get('123')
        assert_equal nil, resp

        resp = dc.set('123', 'xyz')
        assert_equal true, resp

        resp = dc.get('123')
        assert_equal 'xyz', resp

        resp = dc.set('123', 'abc')
        assert_equal true, resp

        dc.prepend('123', '0')
        dc.append('123', '0')

        assert_raises Dalli::DalliError do
          resp = dc.get('123')
        end

        dc.close
        dc = nil

        dc = Dalli::Client.new('localhost:19122')

        resp = dc.set('456', 'xyz', 0, :raw => true)
        assert_equal true, resp

        resp = dc.prepend '456', '0'
        assert_equal true, resp

        resp = dc.append '456', '9'
        assert_equal true, resp

        resp = dc.get('456', :raw => true)
        assert_equal '0xyz9', resp

        resp = dc.stats
        assert_equal Hash, resp.class

        dc.close
      end
    end
    
    should "support multithreaded access" do
      memcached do |cache|
        cache.flush
        workers = []

        cache.set('f', 'zzz')
        assert_equal true, (cache.cas('f') do |value|
          value << 'z'
        end)
        assert_equal 'zzzz', cache.get('f')

        # Have a bunch of threads perform a bunch of operations at the same time.
        # Verify the result of each operation to ensure the request and response
        # are not intermingled between threads.
        10.times do
          workers << Thread.new do
            100.times do
              cache.set('a', 9)
              cache.set('b', 11)
              inc = cache.incr('cat', 10, 0, 10)
              cache.set('f', 'zzz')
              assert_not_nil(cache.cas('f') do |value|
                value << 'z'
              end)
              assert_equal false, cache.add('a', 11)
              assert_equal({ 'a' => 9, 'b' => 11 }, cache.get_multi(['a', 'b']))
              inc = cache.incr('cat', 10)
              assert_equal 0, inc % 5
              dec = cache.decr('cat', 5)
              assert_equal 11, cache.get('b')
            end
          end
        end

        workers.each { |w| w.join }
        cache.flush
      end
    end

    should 'gracefully handle authentication failures' do
      memcached(19124, '-S') do |dc|
        assert_raise Dalli::DalliError, /32/ do
          dc.set('abc', 123)
        end
      end
    end

    should "handle namespaced keys" do
      memcached do |dc|
        dc = Dalli::Client.new('localhost:19122', :namespace => 'a')
        dc.set('namespaced', 1)
        dc2 = Dalli::Client.new('localhost:19122', :namespace => 'b')
        dc2.set('namespaced', 2)
        assert_equal 1, dc.get('namespaced')
        assert_equal 2, dc2.get('namespaced')
      end
    end

    # OSX: Create a SASL user for the memcached application like so:
    #
    # saslpasswd2 -a memcached -c testuser
    #
    # with password 'testtest'
    context 'in an authenticated environment' do
      setup do
        ENV['MEMCACHE_USERNAME'] = 'testuser'
        ENV['MEMCACHE_PASSWORD'] = 'testtest'
      end

      teardown do
        ENV['MEMCACHE_USERNAME'] = nil
        ENV['MEMCACHE_PASSWORD'] = nil
      end

      should 'support SASL authentication' do
        memcached(19124, '-S') do |dc|
          # I get "Dalli::NetworkError: Error authenticating: 32" in OSX
          # but SASL works on Heroku servers. YMMV.
          assert_equal true, dc.set('abc', 123)
          assert_equal 123, dc.get('abc')
          assert_equal({"localhost:19121"=>{}}, dc.stats)
        end
      end
    end

  end
end
