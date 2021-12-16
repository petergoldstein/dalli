# frozen_string_literal: true

require_relative '../helper'

# This is a binary protocol only set of tests
describe 'Sasl' do
  def self.sasl_it(msg, &block)
    it(msg, &block) if ENV['RUN_SASL_TESTS']
  end

  describe 'when the server is configured to require authentication' do
    before do
      @server = Minitest::Mock.new
      @server.expect(:request, true)
      @server.expect(:weight, 1)
      @server.expect(:name, 'localhost:19124')
    end

    describe 'with incorrect authentication credentials' do
      describe 'from the environment variables' do
        before do
          ENV['MEMCACHE_USERNAME'] = 'foo'
          ENV['MEMCACHE_PASSWORD'] = 'wrongpwd'
        end

        after do
          ENV['MEMCACHE_USERNAME'] = nil
          ENV['MEMCACHE_PASSWORD'] = nil
        end

        sasl_it 'fails and raises the expected error' do
          memcached_sasl_persistent do |_, port|
            dc = Dalli::Client.new("localhost:#{port}")
            assert_error Dalli::DalliError, /0x20/ do
              dc.set('abc', 123)
            end
          end
        end
      end

      describe 'passed in as options' do
        sasl_it 'fails and raises the expected error' do
          memcached_sasl_persistent do |_, port|
            dc = Dalli::Client.new("localhost:#{port}", username: 'foo', password: 'wrongpwd')
            assert_error Dalli::DalliError, /0x20/ do
              dc.set('abc', 123)
            end
          end
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

      sasl_it 'pass SASL authentication' do
        memcached_sasl_persistent do |dc|
          # I get "Dalli::DalliError: Error authenticating: 0x20" in OSX
          # but SASL works on Heroku servers. YMMV.
          assert dc.set('abc', 123)
          assert_equal 123, dc.get('abc')
        end
      end
    end

    sasl_it 'pass SASL authentication with options' do
      memcached_sasl_persistent do |_, port|
        dc = Dalli::Client.new("localhost:#{port}", sasl_credentials)
        # I get "Dalli::DalliError: Error authenticating: 32" in OSX
        # but SASL works on Heroku servers. YMMV.
        assert dc.set('abc', 123)
        assert_equal 123, dc.get('abc')
      end
    end
  end
end
