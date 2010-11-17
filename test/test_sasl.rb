require 'helper'

class TestSasl < Test::Unit::TestCase

  context 'a server requiring authentication' do

    context 'without authentication credentials' do
      setup do
        ENV['MEMCACHE_USERNAME'] = 'testuser'
        ENV['MEMCACHE_PASSWORD'] = 'wrongpwd'
      end

      teardown do
        ENV['MEMCACHE_USERNAME'] = nil
        ENV['MEMCACHE_PASSWORD'] = nil
      end

      should 'gracefully handle authentication failures' do
        memcached(19124, '-S') do |dc|
          assert_raise Dalli::DalliError, /32/ do
            dc.set('abc', 123)
          end
        end
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
          # I get "Dalli::DalliError: Error authenticating: 32" in OSX
          # but SASL works on Heroku servers. YMMV.
          assert_equal true, dc.set('abc', 123)
          assert_equal 123, dc.get('abc')
          assert_equal({"localhost:19121"=>{}}, dc.stats)
        end
      end
    end

  end
end