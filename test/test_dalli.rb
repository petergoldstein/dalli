require 'helper'

class TestDalli < Test::Unit::TestCase
  context 'live server' do
    setup do
      begin
        TCPSocket.new('localhost', 11211)
      rescue => ex
        $skip = true
        puts "Skipping live test as memcached is not running at localhost:11211.  Start it with 'memcached -d'"
      end
    end
    
    should "pass a simple smoke test" do
      return if $skip
      
      dc = Dalli::Client.new('localhost:11211')
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
      
      resp = dc.get('123')
      assert_equal 'abc', resp

      resp = dc.prepend '123', '0'
      assert_equal true, resp

      resp = dc.append '123', '9'
      assert_equal true, resp

      resp = dc.get('123')
      assert_equal '0abc9', resp
      
      resp = dc.stats
      p resp
      assert_equal Hash, resp.class
    end
  end
end
