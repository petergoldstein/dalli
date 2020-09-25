# encoding: utf-8
# frozen_string_literal: true
require_relative 'helper'
require 'connection_pool'
require 'openssl'

class MockUser
  def cache_key
    "users/1/21348793847982314"
  end
end

class MockUserVersioning
  def cache_key_with_version
    "users/1/241012793847982434"
  end
end

class ObjectRaisingEquality
  def ==(other)
    raise "Equality called on fetched object."
  end
end

class MyToParamIsFrozen
  def to_param
    "frozen".freeze
  end
end

describe 'ActiveSupport::Cache::DalliStore' do
  # with and without local cache
  def self.it_with_and_without_local_cache(message, &block)
    it "#{message} with LocalCache" do
      with_cache do
        @dalli.with_local_cache do
          instance_eval(&block)
        end
      end
    end

    it "#{message} without LocalCache" do
      with_cache do
        instance_eval(&block)
      end
    end
  end

  describe 'active_support caching' do
    it 'has accessible options' do
      with_cache :expires_in => 5.minutes, :frob => 'baz' do
        assert_equal 'baz', @dalli.options[:frob]
      end

      with_cache :expires_in => 5.minutes, :digest_class => OpenSSL::Digest::SHA1 do
        assert_equal OpenSSL::Digest::SHA1, @dalli.options[:digest_class]
      end
    end

    it 'uses valid digest_class option' do
      with_cache :expires_in => 5.minutes, :digest_class => OpenSSL::Digest::SHA1 do
        key = "k" * 300
        dvalue = @dalli.fetch(key) { 123 }
        assert_equal 123, dvalue
      end
    end

    it 'uses a fallback digest_class' do
      with_cache :expires_in => 5.minutes do
        key = "k" * 300
        dvalue = @dalli.fetch(key) { 123 }
        assert_equal 123, dvalue
      end
    end

    it_with_and_without_local_cache 'allow mute and silence' do
      @dalli.mute do
        assert op_addset_succeeds(@dalli.write('foo', 'bar', nil))
        assert_equal 'bar', @dalli.read('foo', nil)
      end
      refute @dalli.silence?
      @dalli.silence!
      assert_equal true, @dalli.silence?
    end

    it_with_and_without_local_cache 'handle nil options' do
      assert op_addset_succeeds(@dalli.write('foo', 'bar', nil))
      assert_equal 'bar', @dalli.read('foo', nil)
      assert_equal 18, @dalli.fetch('lkjsadlfk', nil) { 18 }
      assert_equal 18, @dalli.fetch('lkjsadlfk', nil) { 18 }
      assert_equal 1, @dalli.increment('lkjsa', 1)
      assert_equal 2, @dalli.increment('lkjsa', 1)
      assert_equal 1, @dalli.decrement('lkjsa', 1)
      assert_equal true, @dalli.delete('lkjsa')
    end

    describe 'fetch' do
      it_with_and_without_local_cache 'support expires_in' do
        dvalue = @dalli.fetch('someotherkeywithoutspaces', :expires_in => 1.second) { 123 }
        assert_equal 123, dvalue
      end

      it_with_and_without_local_cache 'tests cache misses using correct operand ordering' do
        # Some objects customise their equality methods. If you call #== on these objects this can mean your
        # returned value from the gem to your application is technically different to what's serialised in the cache.
        #
        # See https://github.com/petergoldstein/dalli/pull/662
        #
        obj = ObjectRaisingEquality.new
        @dalli.fetch('obj') { obj }
      end

      it_with_and_without_local_cache 'fallback block gets a key as a parameter' do
        key = rand_key
        o = Object.new
        o.instance_variable_set :@foo, 'bar'
        dvalue = @dalli.fetch(key) { |k| "#{k}-#{o}" }
        assert_equal "#{key}-#{o}", dvalue
      end

      it_with_and_without_local_cache 'support object' do
        o = Object.new
        o.instance_variable_set :@foo, 'bar'
        dvalue = @dalli.fetch(rand_key) { o }
        assert_equal o, dvalue
      end

      it_with_and_without_local_cache 'support object with raw' do
        o = Object.new
        o.instance_variable_set :@foo, 'bar'
        dvalue = @dalli.fetch(rand_key, :raw => true) { o }
        assert_equal o, dvalue
      end

      it_with_and_without_local_cache 'support false value' do
        @dalli.write('false', false)
        dvalue = @dalli.fetch('false') { flunk }
        assert_equal false, dvalue
      end

      it 'support nil value when cache_nils: true' do
        with_cache cache_nils: true do
          @dalli.write('nil', nil)
          dvalue = @dalli.fetch('nil') { flunk }
          assert_nil dvalue
        end

        with_cache cache_nils: false do
          @dalli.write('nil', nil)
          executed = false
          dvalue = @dalli.fetch('nil') { executed = true; 'bar' }
          assert_equal true, executed
          assert_equal 'bar', dvalue
        end
      end

      it_with_and_without_local_cache 'support object with cache_key' do
        user = MockUser.new
        @dalli.write(user.cache_key, false)
        dvalue = @dalli.fetch(user) { flunk }
        assert_equal false, dvalue
      end

      it_with_and_without_local_cache 'support object with cache_key_with_version' do
        user = MockUserVersioning.new
        @dalli.write(user.cache_key_with_version, false)
        dvalue = @dalli.fetch(user) { flunk }
        assert_equal false, dvalue
      end
    end

    it_with_and_without_local_cache 'support keys with spaces' do
      dvalue = @dalli.fetch('some key with spaces', :expires_in => 1.second) { 123 }
      assert_equal 123, dvalue
    end

    it_with_and_without_local_cache 'support read_multi' do
      x = rand_key
      y = rand_key
      assert_equal({}, @dalli.read_multi(x, y))
      @dalli.write(x, '123')
      @dalli.write(y, 123)
      assert_equal({ x => '123', y => 123 }, @dalli.read_multi(x, y))
    end

    it_with_and_without_local_cache 'support read_multi with an array' do
      x = rand_key
      y = rand_key
      assert_equal({}, @dalli.read_multi([x, y]))
      @dalli.write(x, '123')
      @dalli.write(y, 123)
      assert_equal({}, @dalli.read_multi([x, y]))
      @dalli.write([x, y], '123')
      assert_equal({ [x, y] => '123' }, @dalli.read_multi([x, y]))
    end

    it_with_and_without_local_cache 'support read_multi with an empty array' do
      assert_equal({}, @dalli.read_multi([]))
    end

    it 'support raw read_multi' do # TODO fails with LocalCache
      with_cache do
        @dalli.write("abc", 5, :raw => true)
        @dalli.write("cba", 5, :raw => true)
        assert_equal({'abc' => '5', 'cba' => '5' }, @dalli.read_multi("abc", "cba"))
      end
    end

    it 'support read_multi with LocalCache' do
      with_cache do
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

    it 'supports frozen strings' do
      with_cache do
        @dalli.read(["foo".freeze])
      end
    end

    it 'supports frozen strings in more contrived scenarios' do
      with_cache do
        @dalli.read(MyToParamIsFrozen.new)
      end
    end

    it 'support read_multi with special Regexp characters in namespace' do
      # /(?!)/ is a contradictory PCRE and should never be able to match
      with_cache :namespace => '(?!)' do
        @dalli.write('abc', 123)
        @dalli.write('xyz', 456)

        assert_equal({'abc' => 123, 'xyz' => 456}, @dalli.read_multi('abc', 'xyz'))
      end
    end

    it_with_and_without_local_cache 'supports fetch_multi' do
      x = rand_key.to_s
      y = rand_key
      hash = { x => 'ABC', y => 'DEF' }

      @dalli.write(y, '123')

      results = @dalli.fetch_multi(x, y) { |key| hash[key] }

      assert_equal({ x => 'ABC', y => '123' }, results)
      assert_equal('ABC', @dalli.read(x))
      assert_equal('123', @dalli.read(y))
    end

    it_with_and_without_local_cache 'supports fetch_multi with large cache keys' do
      x = "x" * 512
      y = "y" * 512
      hash = { x => 'ABC', y => 'DEF' }

      @dalli.write(y, '123')

      results = @dalli.fetch_multi(x, y) { |key| hash[key] }

      assert_equal({ x => 'ABC', y => '123' }, results)
      assert_equal('ABC', @dalli.read(x))
      assert_equal('123', @dalli.read(y))
    end

    it_with_and_without_local_cache 'support read, write and delete' do
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

      dres = @dalli.write(:false_value, false)
      assert op_addset_succeeds(dres)
      dres = @dalli.read(:false_value)
      assert_equal false, dres

      bigkey = '１２３４５６７８９０１２３４５６７８９０１２３４５６７８９０'
      @dalli.write(bigkey, 'double width')
      assert_equal 'double width', @dalli.read(bigkey)
      assert_equal({bigkey => "double width"}, @dalli.read_multi(bigkey))
    end

    it_with_and_without_local_cache 'support read, write and delete with local namespace' do
      key = 'key_with_namespace'
      namespace_value = @dalli.fetch(key, :namespace => 'namespace') { 123 }
      assert_equal 123, namespace_value

      res = @dalli.read(key, :namespace => 'namespace')
      assert_equal 123, res

      res = @dalli.delete(key, :namespace => 'namespace')
      assert_equal true, res

      res = @dalli.write(key, "foo", :namespace => 'namespace')
      assert op_addset_succeeds(res)

      res = @dalli.read(key, :namespace => 'namespace')
      assert_equal "foo", res
    end

    it_with_and_without_local_cache 'support multi_read and multi_fetch with local namespace' do
      x         = rand_key.to_s
      y         = rand_key
      namespace = 'namespace'
      hash      = { x => 'ABC', y => 'DEF' }

      results = @dalli.fetch_multi(x, y, :namespace => namespace) { |key| hash[key] }

      assert_equal({ x => 'ABC', y => 'DEF' }, results)
      assert_equal('ABC', @dalli.read(x, :namespace => namespace))
      assert_equal('DEF', @dalli.read(y, :namespace => namespace))

      @dalli.write("abc", 5, :namespace => 'namespace')
      @dalli.write("cba", 5, :namespace => 'namespace')
      assert_equal({'abc' => 5, 'cba' => 5 }, @dalli.read_multi("abc", "cba", :namespace => 'namespace'))
    end

    it 'support read, write and delete with LocalCache' do
      with_cache do
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
          assert_nil dres
        end
      end
    end

    it_with_and_without_local_cache 'support unless_exist' do
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

    it_with_and_without_local_cache 'support increment/decrement commands' do
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

      assert_nil @dalli.increment('counterZ1', 1, :initial => nil)
      assert_nil @dalli.read('counterZ1')

      assert_equal 5, @dalli.decrement('counterY2', 1, :initial => 5)
      assert_equal 4, @dalli.decrement('counterY2', 1, :initial => 5)
      assert_equal 4, @dalli.read('counterY2', :raw => true).to_i

      assert_nil @dalli.decrement('counterZ2', 1, :initial => nil)
      assert_nil @dalli.read('counterZ2')

      user = MockUser.new
      assert op_addset_succeeds(@dalli.write(user, 0, :raw => true))
      assert_equal 1, @dalli.increment(user)
      assert_equal 2, @dalli.increment(user)
      assert_equal 1, @dalli.decrement(user)
      assert_equal "1", @dalli.read(user, :raw => true)
    end

    it_with_and_without_local_cache 'support exist command' do
      @dalli.write(:foo, 'a')
      @dalli.write(:false_value, false)

      assert_equal true, @dalli.exist?(:foo)
      assert_equal true, @dalli.exist?(:false_value)

      assert_equal false, @dalli.exist?(:bar)

      user = MockUser.new
      @dalli.write(user, 'foo')
      assert_equal true, @dalli.exist?(user)
    end

    it_with_and_without_local_cache 'support other esoteric commands' do
      ds = @dalli.stats
      assert_equal 1, ds.keys.size
      assert ds[ds.keys.first].keys.size > 0

      @dalli.reset
    end

    it 'respects "raise_errors" option' do
      new_port = 29333
      with_cache port: new_port do
        @dalli.write 'foo', 'bar'
        assert_equal @dalli.read('foo'), 'bar'

        memcached_kill(new_port)

        silence_logger do
          assert_nil @dalli.read('foo')
        end
      end

      with_cache port: new_port, :raise_errors => true do
        memcached_kill(new_port)
        exception = [Dalli::RingError, { :message => "No server available" }]

        silence_logger do
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

    describe 'instruments' do
      it 'notifies errors' do
        new_port = 29333
        key = 'foo'
        with_cache port: new_port, :instrument_errors => true do
          memcached_kill(new_port)
          payload_proc = Proc.new { |payload| payload }
          @dalli.expects(:instrument).with(:read, { :key => key }).yields(&payload_proc).once
          @dalli.expects(:instrument).with(:error, { :key => "DalliError",
                                                     :message => "No server available" }).once
          @dalli.read(key)
        end
      end

      it 'payload hits' do
        with_cache do
          payload = {}
          assert op_addset_succeeds(@dalli.write('false', false))
          foo = @dalli.fetch('burrito') { 'tacos' }
          assert 'tacos', foo

          # NOTE: mocha stubbing for yields
          #       makes the result of the block nil in all cases
          #       there was a ticket about this:
          #       http://floehopper.lighthouseapp.com/projects/22289/tickets/14-8687-blocks-return-value-is-dropped-on-stubbed-yielding-methods
          @dalli.stubs(:instrument).yields payload

          @dalli.read('false')
          assert_equal true, payload.delete(:hit)


          @dalli.fetch('unset_key') { 'tacos' }
          assert_equal false, payload.delete(:hit)

          @dalli.fetch('burrito') { 'tacos' }
          assert_equal true, payload.delete(:hit)

          @dalli.unstub(:instrument)
        end
      end
    end
  end

  it_with_and_without_local_cache 'handle crazy characters from far-away lands' do
    key = "fooƒ"
    value = 'bafƒ'
    assert op_addset_succeeds(@dalli.write(key, value))
    assert_equal value, @dalli.read(key)
  end

  it 'normalize options as expected' do
    with_cache :expires_in => 1, :namespace => 'foo', :compress => true do
      assert_equal 1, @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:expires_in]
      assert_equal 'foo', @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:namespace]
      assert_equal ["localhost:19987"], @dalli.instance_variable_get(:@data).instance_variable_get(:@servers)
    end
  end

  it 'handles nil server with additional options' do
    @dalli = ActiveSupport::Cache::DalliStore.new(nil, :expires_in => 1, :namespace => 'foo', :compress => true)
    assert_equal 1, @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:expires_in]
    assert_equal 'foo', @dalli.instance_variable_get(:@data).instance_variable_get(:@options)[:namespace]
    assert_equal ["127.0.0.1:11211"], @dalli.instance_variable_get(:@data).instance_variable_get(:@servers)
  end

  it 'normalizes servers passed in as comma separated' do
    @dalli = ActiveSupport::Cache::DalliStore.new('server1:2,server3:4')
    assert_equal ['server1:2', 'server3:4'], @dalli.instance_variable_get(:@data).instance_variable_get(:@servers)
  end

  it 'normalizes servers passed in as comma separated, nested in an array' do
    @dalli = ActiveSupport::Cache::DalliStore.new(['server1:2,server3:4', 'server5:6'])
    assert_equal ['server1:2', 'server3:4', 'server5:6'], @dalli.instance_variable_get(:@data).instance_variable_get(:@servers)
  end

  it 'supports connection pooling' do
    with_cache :expires_in => 1, :namespace => 'foo', :compress => true, :pool_size => 3 do
      assert_nil @dalli.read('foo')
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

  it_with_and_without_local_cache 'allow keys to be frozen' do
    key = "foo"
    key.freeze
    assert op_addset_succeeds(@dalli.write(key, "value"))
  end

  it_with_and_without_local_cache 'allow keys from a hash' do
    map = { "one" => "one", "two" => "two" }
    map.each_pair do |k, v|
      assert op_addset_succeeds(@dalli.write(k, v))
    end
    assert_equal map, @dalli.read_multi(*(map.keys))
  end

  def silence_logger
    old = Dalli.logger.level
    Dalli.logger.level = Logger::ERROR + 1
    yield
  ensure
    Dalli.logger.level = old
  end

  def with_cache(options={})
    port = options.delete(:port) || 19987
    memcached_persistent(port) do
      @dalli = ActiveSupport::Cache.lookup_store(:dalli_store, "localhost:#{port}", options)
      @dalli.clear
      yield
    end
  end

  def rand_key
    rand(1_000_000_000)
  end
end
