require 'helper'

describe 'Sasl' do

  # https://github.com/seattlerb/minitest/issues/298
  def self.xit(msg, &block)
  end

  describe 'a server requiring authentication' do
    before do
      @server = mock()
      @server.stubs(:request).returns(true)
      @server.stubs(:weight).returns(1)
      @server.stubs(:hostname).returns("localhost")
      @server.stubs(:port).returns("19124")
    end

    describe 'without authentication credentials' do
      before do
        ENV['MEMCACHE_USERNAME'] = 'foo'
        ENV['MEMCACHE_PASSWORD'] = 'wrongpwd'
      end

      after do
        ENV['MEMCACHE_USERNAME'] = nil
        ENV['MEMCACHE_PASSWORD'] = nil
      end

      it 'provide one test that passes' do
        assert true
      end

      it 'gracefully handle authentication failures' do
        memcached(19124, '-S') do |dc|
          assert_error Dalli::DalliError, /32/ do
            dc.set('abc', 123)
          end
        end
      end
    end

    it 'fail SASL authentication with wrong options' do
      memcached(19124, '-S') do |dc|
        dc = Dalli::Client.new('localhost:19124', :username => 'foo', :password => 'wrongpwd')
        assert_error Dalli::DalliError, /32/ do
          dc.set('abc', 123)
        end
      end
    end

    # OSX: Create a SASL user for the memcached application like so:
    #
    # saslpasswd2 -a memcached -c testuser
    #
    # with password 'testtest'
    describe 'in an authenticated environment' do
      before do
        ENV['MEMCACHE_USERNAME'] = 'testuser'
        ENV['MEMCACHE_PASSWORD'] = 'testtest'
      end

      after do
        ENV['MEMCACHE_USERNAME'] = nil
        ENV['MEMCACHE_PASSWORD'] = nil
      end

      xit 'pass SASL authentication' do
        memcached(19124, '-S') do |dc|
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

    xit 'pass SASL authentication with options' do
      memcached(19124, '-S') do |dc|
        dc = Dalli::Client.new('localhost:19124', :username => 'testuser', :password => 'testtest')
        # I get "Dalli::DalliError: Error authenticating: 32" in OSX
        # but SASL works on Heroku servers. YMMV.
        assert_equal true, dc.set('abc', 123)
        assert_equal 123, dc.get('abc')
        results = dc.stats
        assert_equal 1, results.size
        assert_equal 38, results.values.first.size
      end
    end

    it 'pass SASL as URI' do
      Dalli::Server.expects(:new).with("localhost:19124",
        :username => "testuser", :password => "testtest").returns(@server)
      dc = Dalli::Client.new('memcached://testuser:testtest@localhost:19124')
      dc.flush_all
    end

    it 'pass SASL as ring of URIs' do
      Dalli::Server.expects(:new).with("localhost:19124",
        :username => "testuser", :password => "testtest").returns(@server)
      Dalli::Server.expects(:new).with("otherhost:19125",
        :username => "testuser2", :password => "testtest2").returns(@server)
      dc = Dalli::Client.new(['memcached://testuser:testtest@localhost:19124',
      'memcached://testuser2:testtest2@otherhost:19125'])
      dc.flush_all
    end
  end
end
