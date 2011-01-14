require 'helper'

class TestCompatibility < Test::Unit::TestCase

  def setup
    require 'dalli/memcache-client'
  end

  context 'dalli in memcache-client mode' do

    should 'handle old raw flag to set/add/replace' do
      memcached do |dc|
        assert_equal "STORED\r\n", dc.set('abc', 123, 5, true)
        assert_equal '123', dc.get('abc', true)

        assert_equal "NOT_STORED\r\n", dc.add('abc', 456, 5, true)
        assert_equal '123', dc.get('abc', true)

        assert_equal "STORED\r\n", dc.replace('abc', 456, 5, false)
        assert_equal 456, dc.get('abc', false)

        assert_equal "DELETED\r\n", dc.delete('abc')
        assert_equal "NOT_DELETED\r\n", dc.delete('abc')
      end
    end

  end

  def teardown
    Dalli::Client.compatibility_mode = false
  end

end