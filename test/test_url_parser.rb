# encoding: utf-8
require 'helper'

describe 'URL parser' do
  context "what may appear in ENV['MEMCACHE_URL']" do
    should "pull out various parts" do
      parser = Dalli::UrlParser.new 'memcached://testuser:testtest@1.2.3.4,5.6.7.8,9.10.11.12:19124?namespace=mytest&expires_in=4'
      assert_equal 'testuser', parser.options[:username]
      assert_equal 'testtest', parser.options[:password]
      assert_equal ['1.2.3.4:19124','5.6.7.8:19124','9.10.11.12:19124'], parser.servers
      assert_equal 'mytest', parser.options[:namespace]
      assert_equal 4, parser.options[:expires_in]
    end
  end
end
