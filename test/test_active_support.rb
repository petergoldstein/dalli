# encoding: utf-8
require 'helper'
require 'connection_pool'

class MockUser
  def cache_key
    "users/1/21348793847982314"
  end
end

describe 'ActiveSupport' do
  describe 'active_support caching' do

    it 'has accessible options' do
      @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122', :expires_in => 5.minutes, :frob => 'baz')
      assert_equal 'baz', @dalli.options[:frob]
    end

    it 'allow mute and silence' do
      @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122')
      @dalli.mute do
        assert op_addset_succeeds(@dalli.write('foo', 'bar', nil))
        assert_equal 'bar', @dalli.read('foo', nil)
      end
      refute @dalli.silence?
      @dalli.silence!
      assert_equal true, @dalli.silence?
    end

    it 'handle nil options' do
      @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122')
      assert op_addset_succeeds(@dalli.write('foo', 'bar', nil))
      assert_equal 'bar', @dalli.read('foo', nil)
      assert_equal 18, @dalli.fetch('lkjsadlfk', nil) { 18 }
      assert_equal 18, @dalli.fetch('lkjsadlfk', nil) { 18 }
      assert_equal 1, @dalli.increment('lkjsa', 1, nil)
      assert_equal 2, @dalli.increment('lkjsa', 1, nil)
      assert_equal 1, @dalli.decrement('lkjsa', 1, nil)
      assert_equal true, @dalli.delete('lkjsa')
    end

    it 'support fetch' do
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

          @dalli.write('false', false)
          dvalue = @dalli.fetch('false') { flunk }
          assert_equal false, dvalue

          user = MockUser.new
          @dalli.write(user.cache_key, false)
          dvalue = @dalli.fetch(user) { flunk }
          assert_equal false, dvalue
        end
      end
    end

    it 'support keys with spaces on Rails3' do
      with_activesupport do
        memcached do
          connect
          dvalue = @dalli.fetch('some key with spaces', :expires_in => 1.second) { 123 }
          assert_equal 123, dvalue
        end
      end
    end

    it 'support read_multi' do
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

    it 'support read_multi with an array' do
      with_activesupport do
        memcached do
          connect
          x = rand_key
          y = rand_key
          assert_equal({}, @dalli.read_multi([x, y]))
          @dalli.write(x, '123')
          @dalli.write(y, 123)
          assert_equal({}, @dalli.read_multi([x, y]))
          @dalli.write([x, y], '123')
          assert_equal({ [x, y] => '123' }, @dalli.read_multi([x, y]))
        end
      end
    end

    it 'support raw read_multi' do
      with_activesupport do
        memcached do
          connect
          @dalli.write("abc", 5, :raw => true)
          @dalli.write("cba", 5, :raw => true)
          assert_equal({'abc' => '5', 'cba' => '5' }, @dalli.read_multi("abc", "cba"))
        end
      end
    end

    it 'support read_multi with LocalCache' do
      with_activesupport do
        memcached do
          connect
          x = rand_key
          y = rand_key
          assert_equal({}, @dalli.read_multi(x, y))
          @dalli.write(x, '123')
          @dalli.write(y, 456)

          @dalli.with_local_cache do
            assert_equal({ x => '123', y => 456 }, @dalli.read_multi(x, y))
            Dalli::Client.any_instance.expects(:get).with(any_parameters).never

            dres = @dalli.read(x)
            assert_equal dres, '123'
          end

          Dalli::Client.any_instance.unstub(:get)

          # Fresh LocalStore
          @dalli.with_local_cache do
            @dalli.read(x)
            Dalli::Client.any_instance.expects(:get_multi).with([y.to_s]).returns(y.to_s => 456)

            assert_equal({ x => '123', y => 456}, @dalli.read_multi(x, y))
          end
        end
      end
    end

    it 'supports fetch_multi' do
      with_activesupport do
        memcached do
          connect

          x = rand_key.to_s
          y = rand_key
          hash = { x => 'ABC', y => 'DEF' }

          @dalli.write(y, '123')

          results = @dalli.fetch_multi(x, y) { |key| hash[key] }

          assert_equal({ x => 'ABC', y => '123' }, results)
          assert_equal('ABC', @dalli.read(x))
          assert_equal('123', @dalli.read(y))
        end
      end
    end

    it 'support read, write and delete' do
      with_activesupport do
        memcached do
          connect
          y = rand_key
          assert_nil @dalli.read(y)
          dres = @dalli.write(y, 123)
          assert op_addset_succeeds(dres)

          dres = @dalli.read(y)
          assert_equal 123, dres

          dres = @dalli.delete(y)
          assert_equal true, dres

          user = MockUser.new
          dres = @dalli.write(user.cache_key, "foo")
          assert op_addset_succeeds(dres)

          dres = @dalli.read(user)
          assert_equal "foo", dres

          dres = @dalli.delete(user)
          assert_equal true, dres

          bigkey = '１２３４５６７８９０１２３４５６７８９０１２３４５６７８９０'
          @dalli.write(bigkey, 'double width')
          assert_equal 'double width', @dalli.read(bigkey)
          assert_equal({bigkey => "double width"}, @dalli.read_multi(bigkey))
        end
      end
    end

    it 'support read, write and delete with LocalCache' do
      with_activesupport do
        memcached do
          connect
          y = rand_key.to_s
          @dalli.with_local_cache do
            Dalli::Client.any_instance.expects(:get).with(y, {}).once.returns(123)
            dres = @dalli.read(y)
            assert_equal 123, dres

            Dalli::Client.any_instance.expects(:get).with(y, {}).never

            dres = @dalli.read(y)
            assert_equal 123, dres

            @dalli.write(y, 456)
            dres = @dalli.read(y)
            assert_equal 456, dres

            @dalli.delete(y)
            Dalli::Client.any_instance.expects(:get).with(y, {}).once.returns(nil)
            dres = @dalli.read(y)
            assert_equal nil, dres
          end
        end
      end
    end

    it 'support unless_exist with LocalCache' do
      with_activesupport do
        memcached do
          connect
          y = rand_key.to_s
          @dalli.with_local_cache do
            Dalli::Client.any_instance.expects(:add).with(y, 123, nil, {:unless_exist => true}).once.returns(true)
            dres = @dalli.write(y, 123, :unless_exist => true)
            assert_equal true, dres

            Dalli::Client.any_instance.expects(:add).with(y, 321, nil, {:unless_exist => true}).once.returns(false)

            dres = @dalli.write(y, 321, :unless_exist => true)
            assert_equal false, dres

            Dalli::Client.any_instance.expects(:get).with(y, {}).once.returns(123)

            dres = @dalli.read(y)
            assert_equal 123, dres
          end
        end
      end
    end

    it 'support increment/decrement commands' do
      with_activesupport do
        memcached do
          connect
          assert op_addset_succeeds(@dalli.write('counter', 0, :raw => true))
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

          user = MockUser.new
          assert op_addset_succeeds(@dalli.write(user, 0, :raw => true))
          assert_equal 1, @dalli.increment(user)
          assert_equal 2, @dalli.increment(user)
          assert_equal 1, @dalli.decrement(user)
          assert_equal "1", @dalli.read(user, :raw => true)
        end
      end
    end

    it 'support exist command' do
      with_activesupport do
        memcached do
          connect
          @dalli.write(:foo, 'a')
          @dalli.write(:false_value, false)

          assert_equal true, @dalli.exist?(:foo)
          assert_equal true, @dalli.exist?(:false_value)

          assert_equal false, @dalli.exist?(:bar)

          user = MockUser.new
          @dalli.write(user, 'foo')
          assert_equal true, @dalli.exist?(user)
        end
      end
    end

    it 'support other esoteric commands' do
      with_activesupport do
        memcached do
          connect
          ds = @dalli.stats
          assert_equal 1, ds.keys.size
          assert ds[ds.keys.first].keys.size > 0

          @dalli.reset
        end
      end
    end

    it 'respect "raise_errors" option' do
      with_activesupport do
        memcached(29125) do
          @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:29125')
          @dalli.write 'foo', 'bar'
          assert_equal @dalli.read('foo'), 'bar'

          memcached_kill(29125)

          assert_equal @dalli.read('foo'), nil

          @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:29125', :raise_errors => true)

          exception = [Dalli::RingError, { :message => "No server available" }]

          assert_raises(*exception) { @dalli.read 'foo' }
          assert_raises(*exception) { @dalli.read 'foo', :raw => true }
          assert_raises(*exception) { @dalli.write 'foo', 'bar' }
          assert_raises(*exception) { @dalli.exist? 'foo' }
          assert_raises(*exception) { @dalli.increment 'foo' }
          assert_raises(*exception) { @dalli.decrement 'foo' }
          assert_raises(*exception) { @dalli.delete 'foo' }
          assert_equal @dalli.read_multi('foo', 'bar'), {}
          assert_raises(*exception) { @dalli.delete 'foo' }
          assert_raises(*exception) { @dalli.fetch('foo') { 42 } }
        end
      end
    end
  end

  it 'handle crazy characters from far-away lands' do
    with_activesupport do
      memcached do
        connect
        key = "fooƒ"
        value = 'bafƒ'
        assert op_addset_succeeds(@dalli.write(key, value))
        assert_equal value, @dalli.read(key)
      end
    end
  end

  it 'normalize options as expected' do
    with_activesupport do
      memcached do
        @dalli = ActiveSupport::Cache::DalliStore.new('localhost:19122', :expires_in => 1, :namespace => 'foo', :compress => true)
        assert_equal 1, @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:expires_in]
        assert_equal 'foo', @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:namespace]
        assert_equal ["localhost:19122"], @dalli.instance_variable_get(:@data).instance_variable_get(:@servers)
      end
    end
  end

  it 'handles nil server with additional options' do
    with_activesupport do
      memcached do
        @dalli = ActiveSupport::Cache::DalliStore.new(nil, :expires_in => 1, :namespace => 'foo', :compress => true)
        assert_equal 1, @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:expires_in]
        assert_equal 'foo', @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:namespace]
        assert_equal ["127.0.0.1:11211"], @dalli.instance_variable_get(:@data).instance_variable_get(:@servers)
      end
    end
  end

  it 'supports connection pooling' do
    with_activesupport do
      memcached do
        @dalli = ActiveSupport::Cache::DalliStore.new('localhost:19122', :expires_in => 1, :namespace => 'foo', :compress => true, :pool_size => 3)
        assert_equal nil, @dalli.read('foo')
        assert @dalli.write('foo', 1)
        assert_equal 1, @dalli.fetch('foo') { raise 'boom' }
        assert_equal true, @dalli.dalli.is_a?(ConnectionPool)
        assert_equal 1, @dalli.increment('bar')
        assert_equal 0, @dalli.decrement('bar')
        assert_equal true, @dalli.delete('bar')
        assert_equal [true], @dalli.clear
        assert_equal 1, @dalli.stats.size
      end
    end
  end

  it 'allow keys to be frozen' do
    with_activesupport do
      memcached do
        connect
        key = "foo"
        key.freeze
        assert op_addset_succeeds(@dalli.write(key, "value"))
      end
    end
  end

  it 'allow keys from a hash' do
    with_activesupport do
      memcached do
        connect
        map = { "one" => "one", "two" => "two" }
        map.each_pair do |k, v|
          assert op_addset_succeeds(@dalli.write(k, v))
        end
        assert_equal map, @dalli.read_multi(*(map.keys))
      end
    end
  end

  def connect
    @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, 'localhost:19122', :expires_in => 10.seconds, :namespace => lambda{33.to_s(36)})
    @dalli.clear
  end

  def rand_key
    rand(1_000_000_000)
  end
end
