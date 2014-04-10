require 'helper'
require 'memcached_mock'

describe 'Dalli' do
  describe 'options parsing' do
    it 'handle deprecated options' do
      dc = Dalli::Client.new('foo', :compression => true)
      assert dc.instance_variable_get(:@options)[:compress]
      refute dc.instance_variable_get(:@options)[:compression]
    end

    it 'not warn about valid options' do
      dc = Dalli::Client.new('foo', :compress => true)
      # Rails.logger.expects :warn
      assert dc.instance_variable_get(:@options)[:compress]
    end

    it 'raises error with invalid expires_in' do
      bad_data = [{:bad => 'expires in data'}, Hash, [1,2,3]]
      bad_data.each do |bad|
        assert_raises ArgumentError do
          Dalli::Client.new('foo', {:expires_in => bad})
        end
      end
    end

    it 'return string type for namespace attribute' do
      dc = Dalli::Client.new('foo', :namespace => :wunderschoen)
      assert_equal "wunderschoen", dc.send(:namespace)
      dc.close

      dc = Dalli::Client.new('foo', :namespace => Proc.new{:wunderschoen})
      assert_equal "wunderschoen", dc.send(:namespace)
      dc.close
    end
  end

  describe 'key validation' do
    it 'not allow blanks' do
      memcached do |dc|
        dc.set '   ', 1
        assert_equal 1, dc.get('   ')
        dc.set "\t", 1
        assert_equal 1, dc.get("\t")
        dc.set "\n", 1
        assert_equal 1, dc.get("\n")
        assert_raises ArgumentError do
          dc.set "", 1
        end
        assert_raises ArgumentError do
          dc.set nil, 1
        end
      end
    end

    it 'allow namespace to be a symbol' do
      memcached(19122, '', :namespace => :wunderschoen) do |dc|
        dc.set "x" * 251, 1
        assert 1, dc.get("#{'x' * 200}:md5:#{Digest::MD5.hexdigest('x' * 251)}")
      end
    end
  end

  it "default to localhost:11211" do
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

    assert_equal '127.0.0.1', s1
    assert_equal s2, s3
  end

  it "accept comma separated string" do
    dc = Dalli::Client.new("server1.example.com:11211,server2.example.com:11211")
    ring = dc.send(:ring)
    assert_equal 2, ring.servers.size
    s1,s2 = ring.servers.map(&:hostname)
    assert_equal "server1.example.com", s1
    assert_equal "server2.example.com", s2
  end

  it "accept array of servers" do
    dc = Dalli::Client.new(["server1.example.com:11211","server2.example.com:11211"])
    ring = dc.send(:ring)
    assert_equal 2, ring.servers.size
    s1,s2 = ring.servers.map(&:hostname)
    assert_equal "server1.example.com", s1
    assert_equal "server2.example.com", s2
  end

  describe 'using a live server' do

    it "support get/set" do
      memcached do |dc|
        dc.flush

        val1 = "1234567890"*105000
        assert_equal false, dc.set('a', val1)

        val1 = "1234567890"*100000
        dc.set('a', val1)
        val2 = dc.get('a')
        assert_equal val1, val2

        assert op_addset_succeeds(dc.set('a', nil))
        assert_nil dc.get('a')
      end
    end

    it 'supports delete' do
      memcached do |dc|
        dc.set('some_key', 'some_value')
        assert_equal 'some_value', dc.get('some_key')

        dc.delete('some_key')
        assert_nil dc.get('some_key')
      end
    end

    it 'returns nil for nonexist key' do
      memcached do |dc|
        assert_equal nil, dc.get('notexist')
      end
    end

    it 'allows "Not found" as value' do
      memcached do |dc|
        dc.set('key1', 'Not found')
        assert_equal 'Not found', dc.get('key1')
      end
    end

    it "support stats" do
      memcached do |dc|
        # make sure that get_hits would not equal 0
        dc.get(:a)

        stats = dc.stats
        servers = stats.keys
        assert(servers.any? do |s|
          stats[s]["get_hits"].to_i != 0
        end, "general stats failed")

        stats_items = dc.stats(:items)
        servers = stats_items.keys
        assert(servers.all? do |s|
          stats_items[s].keys.any? do |key|
            key =~ /items:[0-9]+:number/
          end
        end, "stats items failed")

        stats_slabs = dc.stats(:slabs)
        servers = stats_slabs.keys
        assert(servers.all? do |s|
          stats_slabs[s].keys.any? do |key|
            key == "active_slabs"
          end
        end, "stats slabs failed")

        # reset_stats test
        results = dc.reset_stats
        assert(results.all? { |x| x })
        stats = dc.stats
        servers = stats.keys

        # check if reset was performed
        servers.each do |s|
          assert_equal 0, dc.stats[s]["get_hits"].to_i
        end
      end
    end

    it "support the fetch operation" do
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

    it "support the fetch operation with falsey values" do
      memcached do |dc|
        dc.flush

        dc.set("fetch_key", false)
        res = dc.fetch("fetch_key") { flunk "fetch block called" }
        assert_equal false, res

        dc.set("fetch_key", nil)
        res = dc.fetch("fetch_key") { "bob" }
        assert_equal 'bob', res
      end
    end

    it "support the cas operation" do
      memcached do |dc|
        dc.flush

        expected = { 'blah' => 'blerg!' }

        resp = dc.cas('cas_key') do |value|
          fail('Value it not exist')
        end
        assert_nil resp

        mutated = { 'blah' => 'foo!' }
        dc.set('cas_key', expected)
        resp = dc.cas('cas_key') do |value|
          assert_equal expected, value
          mutated
        end
        assert op_cas_succeeds(resp)

        resp = dc.get('cas_key')
        assert_equal mutated, resp
      end
    end

    it "support multi-get" do
      memcached do |dc|
        dc.close
        dc.flush
        resp = dc.get_multi(%w(a b c d e f))
        assert_equal({}, resp)

        dc.set('a', 'foo')
        dc.set('b', 123)
        dc.set('c', %w(a b c))
        # Invocation without block
        resp = dc.get_multi(%w(a b c d e f))
        expected_resp = { 'a' => 'foo', 'b' => 123, 'c' => %w(a b c) }
        assert_equal(expected_resp, resp)

        # Invocation with block
        dc.get_multi(%w(a b c d e f)) do |k, v|
          assert(expected_resp.has_key?(k) && expected_resp[k] == v)
          expected_resp.delete(k)
        end
        assert expected_resp.empty?

        # Perform a big multi-get with 1000 elements.
        arr = []
        dc.multi do
          1000.times do |idx|
            dc.set idx, idx
            arr << idx
          end
        end

        result = dc.get_multi(arr)
        assert_equal(1000, result.size)
        assert_equal(50, result['50'])
      end
    end

    it 'support raw incr/decr' do
      memcached do |client|
        client.flush

        assert op_addset_succeeds(client.set('fakecounter', 0, 0, :raw => true))
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
        assert op_cas_succeeds(resp)

        resp = client.get('rawcounter', :raw => true)
        assert_equal '10', resp

        resp = client.incr('rawcounter', 1)
        assert_equal 11, resp
      end
    end

    it "support incr/decr operations" do
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
        refute_equal 0x10000000000000000, resp
        dc.reset
      end
    end

    it 'support the append and prepend operations' do
      memcached do |dc|
        dc.flush
        assert op_addset_succeeds(dc.set('456', 'xyz', 0, :raw => true))
        assert_equal true, dc.prepend('456', '0')
        assert_equal true, dc.append('456', '9')
        assert_equal '0xyz9', dc.get('456', :raw => true)
        assert_equal '0xyz9', dc.get('456')

        assert_equal false, dc.append('nonexist', 'abc')
        assert_equal false, dc.prepend('nonexist', 'abc')
      end
    end

    it 'supports replace operation' do
      memcached do |dc|
        dc.flush
        dc.set('key', 'value')
        assert op_replace_succeeds(dc.replace('key', 'value2'))

        assert_equal 'value2', dc.get('key')
      end
    end

    it 'support touch operation' do
      memcached do |dc|
        begin
          dc.flush
          dc.set 'key', 'value'
          assert_equal true, dc.touch('key', 10)
          assert_equal true, dc.touch('key')
          assert_equal 'value', dc.get('key')
          assert_nil dc.touch('notexist')
        rescue Dalli::DalliError => e
          # This will happen when memcached is in lesser version than 1.4.8
          assert_equal 'Response error 129: Unknown command', e.message
        end
      end
    end

    it 'support version operation' do
      memcached do |dc|
        v = dc.version
        servers = v.keys
        assert(servers.any? do |s|
          v[s] != nil
        end, "version failed")
      end
    end

    it 'allow TCP connections to be configured for keepalive' do
      memcached(19122, '', :keepalive => true) do |dc|
        dc.set(:a, 1)
        ring = dc.send(:ring)
        server = ring.servers.first
        socket = server.instance_variable_get('@sock')

        optval = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE)
        optval = optval.unpack 'i'

        assert_equal true, (optval[0] != 0)
      end
    end

    it "pass a simple smoke test" do
      memcached do |dc|
        resp = dc.flush
        refute_nil resp
        assert_equal [true, true], resp

        assert op_addset_succeeds(dc.set(:foo, 'bar'))
        assert_equal 'bar', dc.get(:foo)

        resp = dc.get('123')
        assert_equal nil, resp

        assert op_addset_succeeds(dc.set('123', 'xyz'))

        resp = dc.get('123')
        assert_equal 'xyz', resp

        assert op_addset_succeeds(dc.set('123', 'abc'))

        dc.prepend('123', '0')
        dc.append('123', '0')

        assert_raises Dalli::UnmarshalError do
          resp = dc.get('123')
        end

        dc.close
        dc = nil

        dc = Dalli::Client.new('localhost:19122')

        assert op_addset_succeeds(dc.set('456', 'xyz', 0, :raw => true))

        resp = dc.prepend '456', '0'
        assert_equal true, resp

        resp = dc.append '456', '9'
        assert_equal true, resp

        resp = dc.get('456', :raw => true)
        assert_equal '0xyz9', resp

        assert op_addset_succeeds(dc.set('456', false))

        resp = dc.get('456')
        assert_equal false, resp

        resp = dc.stats
        assert_equal Hash, resp.class

        dc.close
      end
    end

    it "support multithreaded access" do
      memcached do |cache|
        cache.flush
        workers = []

        cache.set('f', 'zzz')
        assert op_cas_succeeds((cache.cas('f') do |value|
          value << 'z'
        end))
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
              res = cache.cas('f') do |value|
                value << 'z'
              end
              refute_nil res
              assert_equal false, cache.add('a', 11)
              assert_equal({ 'a' => 9, 'b' => 11 }, cache.get_multi(['a', 'b']))
              inc = cache.incr('cat', 10)
              assert_equal 0, inc % 5
              cache.decr('cat', 5)
              assert_equal 11, cache.get('b')

              assert_equal %w(a b), cache.get_multi('a', 'b', 'c').keys.sort

            end
          end
        end

        workers.each { |w| w.join }
        cache.flush
      end
    end

    it "handle namespaced keys" do
      memcached do |dc|
        dc = Dalli::Client.new('localhost:19122', :namespace => 'a')
        dc.set('namespaced', 1)
        dc2 = Dalli::Client.new('localhost:19122', :namespace => 'b')
        dc2.set('namespaced', 2)
        assert_equal 1, dc.get('namespaced')
        assert_equal 2, dc2.get('namespaced')
      end
    end

    it "handle nil namespace" do
      memcached do |dc|
        dc = Dalli::Client.new('localhost:19122', :namespace => nil)
        assert_equal 'key', dc.send(:validate_key, 'key')
      end
    end

    it 'truncate cache keys that are too long' do
      memcached do
        dc = Dalli::Client.new('localhost:19122', :namespace => 'some:namspace')
        key = "this cache key is far too long so it must be hashed and truncated and stuff" * 10
        value = "some value"
        assert op_addset_succeeds(dc.set(key, value))
        assert_equal value, dc.get(key)
      end
    end

    it "handle namespaced keys in multi_get" do
      memcached do |dc|
        dc = Dalli::Client.new('localhost:19122', :namespace => 'a')
        dc.set('a', 1)
        dc.set('b', 2)
        assert_equal({'a' => 1, 'b' => 2}, dc.get_multi('a', 'b'))
      end
    end

    it "handle application marshalling issues" do
      memcached do |dc|
        old = Dalli.logger
        Dalli.logger = Logger.new(nil)
        begin
          assert_equal false, dc.set('a', Proc.new { true })
        ensure
          Dalli.logger = old
        end
      end
    end

    describe 'with compression' do
      it 'allow large values' do
        memcached do |dc|
          dalli = Dalli::Client.new(dc.instance_variable_get(:@servers), :compress => true)

          value = "0"*1024*1024
          assert_equal false, dc.set('verylarge', value)
          dalli.set('verylarge', value)
        end
      end
    end

    describe 'in low memory conditions' do

      it 'handle error response correctly' do
        memcached(19125, '-m 1 -M') do |dc|
          failed = false
          value = "1234567890"*100
          1_000.times do |idx|
            begin
              assert op_addset_succeeds(dc.set(idx, value))
            rescue Dalli::DalliError
              failed = true
              assert((800..960).include?(idx), "unexpected failure on iteration #{idx}")
              break
            end
          end
          assert failed, 'did not fail under low memory conditions'
        end
      end

      it 'fit more values with compression' do
        memcached(19126, '-m 1 -M') do |dc|
          dalli = Dalli::Client.new('localhost:19126', :compress => true)
          failed = false
          value = "1234567890"*1000
          10_000.times do |idx|
            begin
              assert op_addset_succeeds(dalli.set(idx, value))
            rescue Dalli::DalliError
              failed = true
              assert((6000..7800).include?(idx), "unexpected failure on iteration #{idx}")
              break
            end
          end
          assert failed, 'did not fail under low memory conditions'
        end
      end

    end

  end
end
