require 'helper'
require 'memcached_mock'
require 'em-synchrony'
require 'em-spec/test'

class TestSynchrony < Test::Unit::TestCase
  include EM::TestHelper

  context 'using a live server' do

    should "support get/set" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc.flush

          val1 = "1234567890"*105000
          assert_error Dalli::DalliError, /too large/ do
            dc.set('a', val1)
            val2 = dc.get('a')
            assert_equal val1, val2
          end

          val1 = "1234567890"*100000
          dc.set('a', val1)
          val2 = dc.get('a')
          assert_equal val1, val2

          assert_equal true, dc.set('a', nil)
          assert_nil dc.get('a')

          done
        end
      end
    end

    should "support the fetch operation" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc.flush

          expected = { 'blah' => 'blerg!' }
          executed = false
          value = dc.fetch('fetch_key') do
            executed = true
            expected
          end
          assert_equal expected, value
          assert_equal true, executed

          executed = false
          value = dc.fetch('fetch_key') do
            executed = true
            expected
          end
          assert_equal expected, value
          assert_equal false, executed

          done
        end
      end
    end

    should "support the cas operation" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc.flush

          expected = { 'blah' => 'blerg!' }

          resp = dc.cas('cas_key') do |value|
            fail('Value should not exist')
          end
          assert_nil resp

          mutated = { 'blah' => 'foo!' }
          dc.set('cas_key', expected)
          resp = dc.cas('cas_key') do |value|
            assert_equal expected, value
            mutated
          end
          assert_equal true, resp

          resp = dc.get('cas_key')
          assert_equal mutated, resp

          # TODO Need to verify failure when value is mutated between get and add.
          done
        end
      end
    end

    should "support multi-get" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc.close
          dc.flush
          resp = dc.get_multi(%w(a b c d e f))
          assert_equal({}, resp)

          dc.set('a', 'foo')
          dc.set('b', 123)
          dc.set('c', %w(a b c))
          resp = dc.get_multi(%w(a b c d e f))
          assert_equal({ 'a' => 'foo', 'b' => 123, 'c' => %w(a b c) }, resp)

          # Perform a huge multi-get with 10,000 elements.
          arr = []
          dc.multi do
            10_000.times do |idx|
              dc.set idx, idx
              arr << idx
            end
          end

          result = dc.get_multi(arr)
          assert_equal(10_000, result.size)
          assert_equal(1000, result['1000'])

          done
        end
      end
    end

    should 'support raw incr/decr' do
      em do
        memcached(19122,'',:async => true) do |client|
          client.flush

          assert_equal true, client.set('fakecounter', 0, 0, :raw => true)
          assert_equal 1, client.incr('fakecounter', 1)
          assert_equal 2, client.incr('fakecounter', 1)
          assert_equal 3, client.incr('fakecounter', 1)
          assert_equal 1, client.decr('fakecounter', 2)
          assert_equal "1", client.get('fakecounter', :raw => true)

          resp = client.incr('mycounter', 0)
          assert_nil resp

          resp = client.incr('mycounter', 1, 0, 2)
          assert_equal 2, resp
          resp = client.incr('mycounter', 1)
          assert_equal 3, resp

          resp = client.set('rawcounter', 10, 0, :raw => true)
          assert_equal true, resp

          resp = client.get('rawcounter', :raw => true)
          assert_equal '10', resp

          resp = client.incr('rawcounter', 1)
          assert_equal 11, resp

          done
        end
      end
    end

    should "support incr/decr operations" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc.flush

          resp = dc.decr('counter', 100, 5, 0)
          assert_equal 0, resp

          resp = dc.decr('counter', 10)
          assert_equal 0, resp

          resp = dc.incr('counter', 10)
          assert_equal 10, resp

          current = 10
          100.times do |x|
            resp = dc.incr('counter', 10)
            assert_equal current + ((x+1)*10), resp
          end

          resp = dc.decr('10billion', 0, 5, 10)
          # go over the 32-bit mark to verify proper (un)packing
          resp = dc.incr('10billion', 10_000_000_000)
          assert_equal 10_000_000_010, resp

          resp = dc.decr('10billion', 1)
          assert_equal 10_000_000_009, resp

          resp = dc.decr('10billion', 0)
          assert_equal 10_000_000_009, resp

          resp = dc.incr('10billion', 0)
          assert_equal 10_000_000_009, resp

          assert_nil dc.incr('DNE', 10)
          assert_nil dc.decr('DNE', 10)

          resp = dc.incr('big', 100, 5, 0xFFFFFFFFFFFFFFFE)
          assert_equal 0xFFFFFFFFFFFFFFFE, resp
          resp = dc.incr('big', 1)
          assert_equal 0xFFFFFFFFFFFFFFFF, resp

          # rollover the 64-bit value, we'll get something undefined.
          resp = dc.incr('big', 1)
          assert_not_equal 0x10000000000000000, resp
          dc.reset

          done
        end
      end
    end

    should 'support the append and prepend operations' do
      em do
        memcached(19122,'',:async => true) do |dc|
          resp = dc.flush
          assert_equal true, dc.set('456', 'xyz', 0, :raw => true)
          assert_equal true, dc.prepend('456', '0')
          assert_equal true, dc.append('456', '9')
          assert_equal '0xyz9', dc.get('456', :raw => true)
          assert_equal '0xyz9', dc.get('456')

          assert_equal false, dc.append('nonexist', 'abc')
          assert_equal false, dc.prepend('nonexist', 'abc')

          done
        end
      end
    end

    should "pass a simple smoke test" do
      em do
        memcached(19122,'',:async => true) do |dc|
          resp = dc.flush
          assert_not_nil resp
          assert_equal [true, true], resp

          assert_equal true, dc.set(:foo, 'bar')
          assert_equal 'bar', dc.get(:foo)

          resp = dc.get('123')
          assert_equal nil, resp

          resp = dc.set('123', 'xyz')
          assert_equal true, resp

          resp = dc.get('123')
          assert_equal 'xyz', resp

          resp = dc.set('123', 'abc')
          assert_equal true, resp

          dc.prepend('123', '0')
          dc.append('123', '0')

          assert_raises Dalli::DalliError do
            resp = dc.get('123')
          end

          dc.close
          dc = nil

          dc = Dalli::Client.new('localhost:19122', :async => true)

          resp = dc.set('456', 'xyz', 0, :raw => true)
          assert_equal true, resp

          resp = dc.prepend '456', '0'
          assert_equal true, resp

          resp = dc.append '456', '9'
          assert_equal true, resp

          resp = dc.get('456', :raw => true)
          assert_equal '0xyz9', resp

          resp = dc.stats
          assert_equal Hash, resp.class

          dc.close
          
          done
        end
      end
    end

    should "handle namespaced keys" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc = Dalli::Client.new('localhost:19122', :namespace => 'a', :async => true)
          dc.set('namespaced', 1)
          dc2 = Dalli::Client.new('localhost:19122', :namespace => 'b', :async => true)
          dc2.set('namespaced', 2)
          assert_equal 1, dc.get('namespaced')
          assert_equal 2, dc2.get('namespaced')

          done
        end
      end
    end

    should "handle namespaced keys in multi_get" do
      em do
        memcached(19122,'',:async => true) do |dc|
          dc = Dalli::Client.new('localhost:19122', :namespace => 'a', :async => true)
          dc.set('a', 1)
          dc.set('b', 2)
          assert_equal({'a' => 1, 'b' => 2}, dc.get_multi('a', 'b'))

          done
        end
      end
    end

    should "handle application marshalling issues" do
      em do
        memcached(19122,'',:async => true) do |dc|
          old = Dalli.logger
          Dalli.logger = Logger.new(nil)
          begin
            assert_equal false, dc.set('a', Proc.new { true })
          ensure
            Dalli.logger = old
          end
        end

        done
      end
    end

    context 'with compression' do
      should 'allow large values' do
        em do
          memcached(19122,'',:async => true) do |dc|
            dalli = Dalli::Client.new(dc.instance_variable_get(:@servers), :compression => true, :async => true)

            value = "0"*1024*1024
            assert_raise Dalli::DalliError, /too large/ do
              dc.set('verylarge', value)
            end
            dalli.set('verylarge', value)
          end

          done
        end
      end
    end

    context 'in low memory conditions' do

      should 'handle error response correctly' do
        em do
          memcached(19125, '-m 1 -M', :async => true) do |dc|
            failed = false
            value = "1234567890"*100
            1_000.times do |idx|
              begin
                assert_equal true, dc.set(idx, value)
              rescue Dalli::DalliError
                failed = true
                assert((800..900).include?(idx), "unexpected failure on iteration #{idx}")
                break
              end
            end
            assert failed, 'did not fail under low memory conditions'
          end

          done
        end
      end

      should 'fit more values with compression' do
        em do
          memcached(19126, '-m 1 -M', :async => true ) do |dc|
            dalli = Dalli::Client.new('localhost:19126', :compression => true, :async => true)
            failed = false
            value = "1234567890"*1000
            10_000.times do |idx|
              begin
                assert_equal true, dalli.set(idx, value)
              rescue Dalli::DalliError
                failed = true
                assert((6000..7000).include?(idx), "unexpected failure on iteration #{idx}")
                break
              end
            end
            assert failed, 'did not fail under low memory conditions'

            done
          end
        end
      end

    end

  end
end
