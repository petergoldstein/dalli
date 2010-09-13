require 'helper'
require 'rails'

class TestActiveSupport < Test::Unit::TestCase
  context 'active_support caching' do

    should 'support fetch' do
      with_activesupport do
        memcached do
          connect
          dvalue = @mc.fetch('somekeywithoutspaces', :expires_in => 1.second) { 123 }
          mvalue = @dalli.fetch('someotherkeywithoutspaces', :expires_in => 1.second) { 123 }
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
      end
    end

    should 'support keys with spaces' do
      with_activesupport do
        memcached do
          connect
          dvalue = @mc.fetch('some key with spaces', :expires_in => 1.second) { 123 }
          mvalue = @dalli.fetch('some other key with spaces', :expires_in => 1.second) { 123 }
          assert_equal mvalue, dvalue
        end
      end
    end      

    should 'support read_multi' do
      with_activesupport do
        memcached do
          connect
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
      end
    end

    should 'support read, write and delete' do
      with_activesupport do
        memcached do
          connect
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
      end
    end
    
    should 'support other esoteric commands' do
      with_activesupport do
        memcached do
          connect
          ms = @mc.stats
          ds = @dalli.stats
          assert_equal ms.keys.sort, ds.keys.sort
          assert_equal ms[ms.keys.first].keys.sort, ds[ds.keys.first].keys.sort

          @dalli.reset
        end
      end
    end
  end
  
  def connect
    @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122', :expires_in => 10.seconds, :namespace => 'x')
    @mc = ActiveSupport::Cache.lookup_store(:mem_cache_store, 'localhost:19122', :expires_in => 10.seconds, :namespace => 'a')
    @dalli.clear
  end

  def rand_key
    rand(1_000_000_000)
  end
end