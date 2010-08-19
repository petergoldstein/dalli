require 'helper'
require 'active_support/all'
require 'active_support/cache/dalli_store'

class TestDalli < Test::Unit::TestCase
  context 'activesupport caching' do
    setup do
      @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:11211', :expires_in => 10.seconds)
      @mc = ActiveSupport::Cache.lookup_store(:mem_cache_store, 'localhost:11211', :expires_in => 10.seconds, :namespace => 'a')
      @dalli.clear
    end

    should 'support fetch' do
      dvalue = @mc.fetch('some key with spaces', :expires_in => 1.second) { 123 }
      mvalue = @dalli.fetch('some other key with spaces', :expires_in => 1.second) { 123 }
      assert_equal mvalue, dvalue

      o = Object.new
      o.instance_variable_set :@foo, 'bar'
      dvalue = @mc.fetch(rand_key, :raw => true) { o }
      mvalue = @dalli.fetch(rand_key, :raw => true) { o }
      assert_equal mvalue, dvalue
      assert_equal o, dvalue

      dvalue = @mc.fetch(rand_key) { o }
      mvalue = @dalli.fetch(rand_key) { o }
      assert_equal mvalue, dvalue
      assert_equal o, dvalue
    end

    should 'support read_multi' do
      x = rand_key
      y = rand_key
      assert_equal({}, @mc.read_multi(x, y))
      assert_equal({}, @dalli.read_multi(x, y))
      @dalli.write(x, '123')
      @dalli.write(y, 123)
      @mc.write(x, '123')
      @mc.write(y, 123)
      assert_equal({ x => '123', y => 123 }, @dalli.read_multi(x, y))
      assert_equal({ x => '123', y => 123 }, @mc.read_multi(x, y))
    end

    should 'support read, write and delete' do
      x = rand_key
      y = rand_key
      assert_nil @mc.read(x)
      assert_nil @dalli.read(y)
      mres = @mc.write(x, 123)
      dres = @dalli.write(y, 123)
      assert_equal mres, dres

      mres = @mc.read(x)
      dres = @dalli.read(y)
      assert_equal mres, dres
      assert_equal 123, dres
      
      mres = @mc.delete(x)
      dres = @dalli.delete(y)
      assert_equal mres, dres
      assert_equal true, dres
    end
    
    should 'support other esoteric commands' do
      ms = @mc.stats
      ds = @dalli.stats
      assert_equal ms.keys.sort, ds.keys.sort
      assert_equal ms[ms.keys.first].keys.sort, ds[ds.keys.first].keys.sort
    end
  end

  def rand_key
    rand(1_000_000_000)
  end
end