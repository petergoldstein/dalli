require 'helper'

class TestDalli < Test::Unit::TestCase
  context 'using a live server' do
    setup do
      begin
        TCPSocket.new('localhost', 11211)
      rescue => ex
        $skip = true
        puts "Skipping live test as memcached is not running at localhost:11211.  Start it with 'memcached -d'"
      end
    end

    should "support multi-get" do
      return if $skip
      dc = Dalli::Client.new(['localhost:11211', '127.0.0.1'])
      resp = dc.get_multi(%w(a b c d e f))
      assert_equal({}, resp)

      dc.set('a', 'foo')
      dc.set('b', 123)
      dc.set('c', %w(a b c))
      resp = dc.get_multi(%w(a b c d e f))
      assert_equal({ 'a' => 'foo', 'b' => 123, 'c' => %w(a b c) }, resp)
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

      assert_raises Dalli::DalliError do
        dc.prepend('123', '0')
      end

      assert_raises Dalli::DalliError do
        dc.append('123', '0')
      end

      resp = dc.get('123')
      assert_equal 'abc', resp
      dc.close
      dc = nil

      dc = Dalli::Client.new('localhost:11211', :marshal => false)

      resp = dc.set('456', 'xyz')
      assert_equal true, resp
      
      resp = dc.prepend '456', '0'
      assert_equal true, resp

      resp = dc.append '456', '9'
      assert_equal true, resp

      resp = dc.get('456')
      assert_equal '0xyz9', resp
      
      resp = dc.stats
      assert_equal Hash, resp.class
    end
  end
end
