# frozen_string_literal: true

require_relative 'helper'

describe 'Sasl' do
  # https://github.com/seattlerb/minitest/issues/298
  def self.xit(msg, &block); end

  describe 'a server requiring authentication' do
    before do
      @server = Minitest::Mock.new
      @server.expect(:request, true)
      @server.expect(:weight, 1)
      @server.expect(:name, 'localhost:19124')
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

      xit 'gracefully handle authentication failures' do
        memcached_sasl_persistent do |dc|
          assert_error Dalli::DalliError, /32/ do
            dc.set('abc', 123)
          end
        end
      end
    end

    xit 'fail SASL authentication with wrong options' do
      memcached_sasl_persistent do |_, port|
        dc = Dalli::Client.new("localhost:#{port}", username: 'testuser', password: 'testtest')
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
        memcached_sasl_persistent do |dc|
          # I get "Dalli::DalliError: Error authenticating: 32" in OSX
          # but SASL works on Heroku servers. YMMV.
          assert dc.set('abc', 123)
          assert_equal 123, dc.get('abc')
          results = dc.stats
          assert_equal 1, results.size
          assert_equal 38, results.values.first.size
        end
      end
    end

    xit 'pass SASL authentication with options' do
      memcached_sasl_persistent do |_, port|
        dc = Dalli::Client.new("localhost:#{port}", sasl_credentials)
        # I get "Dalli::DalliError: Error authenticating: 32" in OSX
        # but SASL works on Heroku servers. YMMV.
        assert dc.set('abc', 123)
        assert_equal 123, dc.get('abc')
        results = dc.stats
        assert_equal 1, results.size
        assert_equal 38, results.values.first.size
      end
    end
  end
end
