require 'helper'
require 'memcached_mock'
if defined?(RUBY_ENGINE) && RUBY_ENGINE != 'jruby'
begin
require 'em-spec/test'

describe 'Synchrony' do
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

    context 'with compression' do
      should 'allow large values' do
        em do
          memcached(19122,'',:async => true) do |dc|
            dalli = Dalli::Client.new(dc.instance_variable_get(:@servers), :compression => true, :async => true)

            value = "0"*1024*1024
            assert_raises Dalli::DalliError, /too large/ do
              dc.set('verylarge', value)
            end
            dalli.set('verylarge', value)
          end

          done
        end
      end
    end

  end
end
rescue LoadError
  puts "Skipping em-synchrony tests"
end
end
