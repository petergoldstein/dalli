require 'helper'

class TestActiveSupport < Test::Unit::TestCase
  context 'active_support caching' do

    should 'support fetch' do
      with_activesupport do
        memcached do
          connect
          mvalue = @mc.fetch('somekeywithoutspaces', :expires_in => 1.second) { 123 }
          dvalue = @dalli.fetch('someotherkeywithoutspaces', :expires_in => 1.second) { 123 }
          assert_equal 123, dvalue
          assert_equal mvalue, dvalue

          o = Object.new
          o.instance_variable_set :@foo, 'bar'
          mvalue = @mc.fetch(rand_key, :raw => true) { o }
          dvalue = @dalli.fetch(rand_key, :raw => true) { o }
          assert_equal mvalue, dvalue
          assert_equal o, mvalue

          mvalue = @mc.fetch(rand_key) { o }
          dvalue = @dalli.fetch(rand_key) { o }
          assert_equal mvalue, dvalue
          assert_equal o, dvalue
        end
      end
    end

    should 'support keys with spaces on Rails3' do
      with_activesupport do
        memcached do
          connect
          case 
          when rails3?
            dvalue = @mc.fetch('some key with spaces', :expires_in => 1.second) { 123 }
            mvalue = @dalli.fetch('some other key with spaces', :expires_in => 1.second) { 123 }
            assert_equal mvalue, dvalue
          else
            assert_raises ArgumentError do
              @mc.fetch('some key with spaces', :expires_in => 1.second) { 123 }
            end
            assert_raises ArgumentError do
              @dalli.fetch('some other key with spaces', :expires_in => 1.second) { 123 }
            end
          end
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

    should 'support raw read_multi' do
      with_activesupport do
        memcached do
          connect
          @mc.write("abc", 5, :raw => true)
          @mc.write("cba", 5, :raw => true)
          if RAILS_VERSION =~ /2\.3/
            assert_raise ArgumentError do
              @mc.read_multi("abc", "cba")
            end
          else
            assert_equal({'abc' => '5', 'cba' => '5' }, @mc.read_multi("abc", "cba"))
          end

          @dalli.write("abc", 5, :raw => true)
          @dalli.write("cba", 5, :raw => true)
          # XXX: API difference between m-c and dalli.  Dalli is smarter about
          # what it needs to unmarshal.
          assert_equal({'abc' => '5', 'cba' => '5' }, @dalli.read_multi("abc", "cba"))
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
    
    should 'support increment/decrement commands' do
      with_activesupport do
        memcached do
          connect
          assert_equal true, @mc.write('counter', 0, :raw => true)
          assert_equal 1, @mc.increment('counter')
          assert_equal 2, @mc.increment('counter')
          assert_equal 1, @mc.decrement('counter')
          assert_equal "1", @mc.read('counter', :raw => true)

          assert_equal true, @dalli.write('counter', 0, :raw => true)
          assert_equal 1, @dalli.increment('counter')
          assert_equal 2, @dalli.increment('counter')
          assert_equal 1, @dalli.decrement('counter')
          assert_equal "1", @dalli.read('counter', :raw => true)
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

          assert_equal true, @dalli.write(:foo, 'a')
          assert_equal true, @mc.write(:foo, 'a')

          assert_equal true, @mc.exist?(:foo)
          assert_equal true, @dalli.exist?(:foo)

          assert_equal false, @mc.exist?(:bar)
          assert_equal false, @dalli.exist?(:bar)

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