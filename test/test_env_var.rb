require 'helper'

describe 'environment variables' do
  before do
    @old_memcache_url = ENV.delete 'MEMCACHE_URL'
    @old_memcache_servers = ENV.delete 'MEMCACHE_SERVERS'
    @old_memcache_username = ENV.delete 'MEMCACHE_USERNAME'
    @old_memcache_password = ENV.delete 'MEMCACHE_PASSWORD'
  end

  after do
    ENV['MEMCACHE_URL'] = @old_memcache_url
    ENV['MEMCACHE_SERVERS'] = @old_memcache_servers
    ENV['MEMCACHE_USERNAME'] = @old_memcache_username
    ENV['MEMCACHE_PASSWORD'] = @old_memcache_password
  end

  context 'a single server' do
    before do
      ENV['MEMCACHE_URL'] = 'memcached://1.2.3.4:19124?namespace=mytest&expires_in=4'
    end
    should "use MEMCACHE_URL if no args are passed" do
      dc = Dalli::Client.new
      assert_equal 'mytest', dc.instance_variable_get(:@options)[:namespace]
      assert_equal 4, dc.instance_variable_get(:@options)[:expires_in]
      ring = dc.send(:ring)
      assert_equal '1.2.3.4', ring.servers[0].hostname
      assert_equal 19124, ring.servers[0].port
      assert_equal 1, ring.servers.size
      dc.close
    end
    should "ignore MEMCACHE_URL if args are passed" do
      dc = Dalli::Client.new('9.9.9.9:4444')
      assert_equal nil, dc.instance_variable_get(:@options)[:namespace]
      assert_equal 0, dc.instance_variable_get(:@options)[:expires_in]
      ring = dc.send(:ring)
      assert_equal '9.9.9.9', ring.servers[0].hostname
      assert_equal 4444, ring.servers[0].port
      assert_equal 1, ring.servers.size
      dc.close
    end
  end

  context 'multiple servers in a pool' do
    before do
      ENV['MEMCACHE_URL'] = 'memcached://1.2.3.4,5.6.7.8,9.10.11.12:19124?namespace=mytest&expires_in=4'
    end
    should "use MEMCACHE_URL if no args are passed" do
      dc = Dalli::Client.new
      assert_equal 'mytest', dc.instance_variable_get(:@options)[:namespace]
      assert_equal 4, dc.instance_variable_get(:@options)[:expires_in]
      ring = dc.send(:ring)
      assert_equal '1.2.3.4', ring.servers[0].hostname
      assert_equal '5.6.7.8', ring.servers[1].hostname
      assert_equal '9.10.11.12', ring.servers[2].hostname
      assert_equal 3, ring.servers.size
      dc.close
    end
  end

  context 'a single server requiring authentication' do
    before do
      ENV['MEMCACHE_URL'] = 'memcached://testuser:testtest@1.2.3.4:19124?namespace=mytest&expires_in=4'
    end
    should "use MEMCACHE_URL if no args are passed" do
      dc = Dalli::Client.new
      assert_equal 'mytest', dc.instance_variable_get(:@options)[:namespace]
      assert_equal 4, dc.instance_variable_get(:@options)[:expires_in]
      ring = dc.send(:ring)
      assert_equal '1.2.3.4', ring.servers.first.hostname
      assert_equal 'testuser', ring.servers[0].send(:username)
      assert_equal 'testtest', ring.servers[0].send(:password)
      assert_equal 1, ring.servers.size
      dc.close
    end
    should "ignore MEMCACHE_URL if args are passed" do
      dc = Dalli::Client.new('9.9.9.9:4444')
      assert_equal nil, dc.instance_variable_get(:@options)[:namespace]
      assert_equal 0, dc.instance_variable_get(:@options)[:expires_in]
      ring = dc.send(:ring)
      assert_equal '9.9.9.9', ring.servers.first.hostname
      assert_equal 4444, ring.servers.first.port
      assert_equal nil, ring.servers[0].send(:username)
      assert_equal nil, ring.servers[0].send(:password)
      assert_equal 1, ring.servers.size
      dc.close
    end

    # what follows are taken from test_sasl... not sure if they're 100% necessary

    context 'without authentication credentials' do
      should_eventually 'gracefully handle authentication failures' do
        ENV['MEMCACHE_URL'] = 'memcached://localhost:19124'
        memcached(19124, '-S') do |_|
          dc = Dalli::Client.new
          assert_raise Dalli::DalliError, /32/ do
            dc.set('abc', 123)
          end
        end
      end
    end
    should_eventually 'fail SASL authentication with wrong options' do
      ENV['MEMCACHE_URL'] = 'memcached://foo:wrongpwd@localhost:19124'
      memcached(19124, '-S') do |_|
        dc = Dalli::Client.new
        assert_raise Dalli::DalliError, /32/ do
          dc.set('abc', 123)
        end
      end
    end
    context 'in an authenticated environment' do
      should_eventually 'pass SASL authentication' do
        ENV['MEMCACHE_URL'] = 'memcached://testuser:testtest@localhost:19124'
        memcached(19124, '-S') do |_|
          dc = Dalli::Client.new
          # I get "Dalli::DalliError: Error authenticating: 32" in OSX
          # but SASL works on Heroku servers. YMMV.
          assert_equal true, dc.set('abc', 123)
          assert_equal 123, dc.get('abc')
          results = dc.stats
          assert_equal 1, results.size
          assert_equal 38, results.values.first.size
        end
      end
    end
  end

  context 'a pool of servers requiring authentication' do
    before do
      ENV['MEMCACHE_URL'] = 'memcached://testuser:testtest@1.2.3.4,5.6.7.8,9.10.11.12:19124?namespace=mytest&expires_in=4'
    end
    should "use the same auth credentials everywhere" do
      dc = Dalli::Client.new
      assert_equal 'mytest', dc.instance_variable_get(:@options)[:namespace]
      assert_equal 4, dc.instance_variable_get(:@options)[:expires_in]
      ring = dc.send(:ring)
      assert_equal '1.2.3.4', ring.servers[0].hostname
      assert_equal '5.6.7.8', ring.servers[1].hostname
      assert_equal '9.10.11.12', ring.servers[2].hostname
      assert_equal 3, ring.servers.size
      ring.servers.each do |server|
        assert_equal 'testuser', server.send(:username)
        assert_equal 'testtest', server.send(:password)
      end
      dc.close
    end
  end

  describe "the interaction of MEMCACHE_URL and MEMCACHE_{SERVERS,USERNAME,PASSWORD}" do
    context 'when MEMCACHE_URL is set but so is MEMCACHE_SERVERS' do
      before do
        ENV['MEMCACHE_URL'] = 'memcached://1.2.3.4:19124?namespace=mytest&expires_in=4'
        ENV['MEMCACHE_SERVERS'] = '4.3.2.1'
      end
      should "ignore MEMCACHE_URL" do
        dc = Dalli::Client.new
        assert_equal nil, dc.instance_variable_get(:@options)[:namespace]
        assert_equal 0, dc.instance_variable_get(:@options)[:expires_in]
        ring = dc.send(:ring)
        assert_equal '4.3.2.1', ring.servers[0].hostname
        assert_equal 1, ring.servers.size
      end
    end

    context 'when MEMCACHE_URL is set but so are MEMCACHE_{SERVERS,USERNAME,PASSWORD}' do
      before do
        ENV['MEMCACHE_URL'] = 'memcached://1.2.3.4:19124?namespace=mytest&expires_in=4'
        ENV['MEMCACHE_SERVERS'] = '4.3.2.1'
        ENV['MEMCACHE_USERNAME'] = 'foo'
        ENV['MEMCACHE_PASSWORD'] = 'bar'
      end
      should "ignore MEMCACHE_URL" do
        dc = Dalli::Client.new
        assert_equal nil, dc.instance_variable_get(:@options)[:namespace]
        assert_equal 0, dc.instance_variable_get(:@options)[:expires_in]
        ring = dc.send(:ring)
        assert_equal '4.3.2.1', ring.servers[0].hostname
        assert_equal 'foo', ring.servers[0].send(:username)
        assert_equal 'bar', ring.servers[0].send(:password)
        assert_equal 1, ring.servers.size
      end
    end

    # hmm
    context 'when MEMCACHE_URL is set but so are MEMCACHE_{USERNAME,PASSWORD}' do
      before do
        ENV['MEMCACHE_USERNAME'] = 'foo'
        ENV['MEMCACHE_PASSWORD'] = 'bar'
      end
      should "combine MEMCACHE_USERNAME and MEMCACHE_PASSWORD with MEMCACHE_USERNAME (!!)" do
        ENV['MEMCACHE_URL'] = 'memcached://1.2.3.4:19124?namespace=mytest&expires_in=4'
        dc = Dalli::Client.new
        assert_equal 'mytest', dc.instance_variable_get(:@options)[:namespace]
        assert_equal 4, dc.instance_variable_get(:@options)[:expires_in]
        ring = dc.send(:ring)
        assert_equal '1.2.3.4', ring.servers.first.hostname
        assert_equal 'foo', ring.servers[0].send(:username)
        assert_equal 'bar', ring.servers[0].send(:password)
        assert_equal 1, ring.servers.size
        dc.close
      end
      should "combine properly when there's a pool" do
        ENV['MEMCACHE_URL'] = 'memcached://1.2.3.4,5.6.7.8,9.10.11.12:19124?namespace=mytest&expires_in=4'
        dc = Dalli::Client.new
        assert_equal 'mytest', dc.instance_variable_get(:@options)[:namespace]
        assert_equal 4, dc.instance_variable_get(:@options)[:expires_in]
        ring = dc.send(:ring)
        assert_equal '1.2.3.4', ring.servers[0].hostname
        assert_equal '5.6.7.8', ring.servers[1].hostname
        assert_equal '9.10.11.12', ring.servers[2].hostname
        assert_equal 3, ring.servers.size
        ring.servers.each do |server|
          assert_equal 'foo', server.send(:username)
          assert_equal 'bar', server.send(:password)
        end
        dc.close
      end
    end
  end
end
