# encoding: utf-8
require 'helper'

describe 'ActiveSupport' do
  context 'active_support caching' do

    should 'dalli_store operations should handle nil options' do
      @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122')
      assert_equal true, @dalli.write('foo', 'bar', nil)
      assert_equal 'bar', @dalli.read('foo', nil)
      assert_equal 18, @dalli.fetch('lkjsadlfk', nil) { 18 }
      assert_equal 18, @dalli.fetch('lkjsadlfk', nil) { 18 }
      assert_equal 1, @dalli.increment('lkjsa', 1, nil)
      assert_equal 2, @dalli.increment('lkjsa', 1, nil)
      assert_equal 1, @dalli.decrement('lkjsa', 1, nil)
      assert_equal true, @dalli.delete('lkjsa')
    end

    should 'support fetch' do
      with_activesupport do
        memcached do
          connect
          dvalue = @dalli.fetch('someotherkeywithoutspaces', :expires_in => 1.second) { 123 }
          assert_equal 123, dvalue

          o = Object.new
          o.instance_variable_set :@foo, 'bar'
          dvalue = @dalli.fetch(rand_key, :raw => true) { o }
          assert_equal o, dvalue

          dvalue = @dalli.fetch(rand_key) { o }
          assert_equal o, dvalue
        end
      end
    end

    should 'support keys with spaces on Rails3' do
      with_activesupport do
        memcached do
          connect
          dvalue = @dalli.fetch('some key with spaces', :expires_in => 1.second) { 123 }
          assert_equal 123, dvalue
        end
      end
    end

    should 'support read_multi' do
      with_activesupport do
        memcached do
          connect
          x = rand_key
          y = rand_key
          assert_equal({}, @dalli.read_multi(x, y))
          @dalli.write(x, '123')
          @dalli.write(y, 123)
          assert_equal({ x => '123', y => 123 }, @dalli.read_multi(x, y))
        end
      end
    end

    should 'support read_multi with an array' do
      with_activesupport do
        memcached do
          connect
          x = rand_key
          y = rand_key
          assert_equal({}, @dalli.read_multi([x, y]))
          @dalli.write(x, '123')
          @dalli.write(y, 123)
          assert_equal({ x => '123', y => 123 }, @dalli.read_multi([x, y]))
        end
      end
    end

    should 'support raw read_multi' do
      with_activesupport do
        memcached do
          connect
          @dalli.write("abc", 5, :raw => true)
          @dalli.write("cba", 5, :raw => true)
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
          assert_nil @dalli.read(y)
          dres = @dalli.write(y, 123)
          assert_equal true, dres

          dres = @dalli.read(y)
          assert_equal 123, dres

          dres = @dalli.delete(y)
          assert_equal true, dres
        end
      end
    end

    should 'support increment/decrement commands' do
      with_activesupport do
        memcached do
          connect
          assert_equal true, @dalli.write('counter', 0, :raw => true)
          assert_equal 1, @dalli.increment('counter')
          assert_equal 2, @dalli.increment('counter')
          assert_equal 1, @dalli.decrement('counter')
          assert_equal "1", @dalli.read('counter', :raw => true)

          assert_equal 1, @dalli.increment('counterX')
          assert_equal 2, @dalli.increment('counterX')
          assert_equal 2, @dalli.read('counterX', :raw => true).to_i

          assert_equal 5, @dalli.increment('counterY1', 1, :initial => 5)
          assert_equal 6, @dalli.increment('counterY1', 1, :initial => 5)
          assert_equal 6, @dalli.read('counterY1', :raw => true).to_i

          assert_equal nil, @dalli.increment('counterZ1', 1, :initial => nil)
          assert_equal nil, @dalli.read('counterZ1')

          assert_equal 5, @dalli.decrement('counterY2', 1, :initial => 5)
          assert_equal 4, @dalli.decrement('counterY2', 1, :initial => 5)
          assert_equal 4, @dalli.read('counterY2', :raw => true).to_i

          assert_equal nil, @dalli.decrement('counterZ2', 1, :initial => nil)
          assert_equal nil, @dalli.read('counterZ2')
        end
      end
    end

    should 'support other esoteric commands' do
      with_activesupport do
        memcached do
          connect
          ds = @dalli.stats
          assert_equal 1, ds.keys.size
          assert ds[ds.keys.first].keys.size > 0

          assert_equal true, @dalli.write(:foo, 'a')
          assert_equal true, @dalli.exist?(:foo)
          assert_equal false, @dalli.exist?(:bar)

          @dalli.reset
        end
      end
    end
  end

  should 'handle crazy characters from far-away lands' do
    with_activesupport do
      memcached do
        connect
        key = "fooƒ"
        value = 'bafƒ'
        assert_equal true, @dalli.write(key, value)
        assert_equal value, @dalli.read(key)
      end
    end
  end

  should 'normalize options as expected' do
    with_activesupport do
      memcached do
        @dalli = ActiveSupport::Cache::DalliStore.new('localhost:19122', :expires_in => 1, :namespace => 'foo', :compress => true)
        assert_equal 1, @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:expires_in]
        assert_equal 'foo', @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:namespace]
      end
    end
  end

  def connect
    @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122', :expires_in => 10.seconds, :namespace => 'x')
    @dalli.clear
  end

  def rand_key
    rand(1_000_000_000)
  end
end
