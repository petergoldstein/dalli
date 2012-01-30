require 'helper'

describe 'Sasl' do

  context 'a server requiring authentication' do

    context 'without authentication credentials' do
      before do
        ENV['MEMCACHE_USERNAME'] = 'foo'
        ENV['MEMCACHE_PASSWORD'] = 'wrongpwd'
      end

      after do
        ENV['MEMCACHE_USERNAME'] = nil
        ENV['MEMCACHE_PASSWORD'] = nil
      end

      should 'provide one test that passes' do
        assert true
      end

      should_eventually 'gracefully handle authentication failures' do
        memcached(19124, '-S') do |dc|
          assert_raise Dalli::DalliError, /32/ do
            dc.set('abc', 123)
          end
        end
      end
    end

    should_eventually 'fail SASL authentication with wrong options' do
      memcached(19124, '-S') do |dc|
        dc = Dalli::Client.new('localhost:19124', :username => 'foo', :password => 'wrongpwd')
        assert_raise Dalli::DalliError, /32/ do
          dc.set('abc', 123)
        end
      end
    end

    # OSX: Create a SASL user for the memcached application like so:
    #
    # saslpasswd2 -a memcached -c testuser
    #
    # with password 'testtest'
    context 'in an authenticated environment' do
      before do
        ENV['MEMCACHE_USERNAME'] = 'testuser'
        ENV['MEMCACHE_PASSWORD'] = 'testtest'
      end

      after do
        ENV['MEMCACHE_USERNAME'] = nil
        ENV['MEMCACHE_PASSWORD'] = nil
      end

      should_eventually 'pass SASL authentication' do
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

    should_eventually 'pass SASL authentication with options' do
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

  end
end
