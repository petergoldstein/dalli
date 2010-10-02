require 'helper'
require 'benchmark'

class TestBenchmark < Test::Unit::TestCase

  def setup
    puts "Testing #{Dalli::VERSION} with #{RUBY_DESCRIPTION}"
    # We'll use a simple @value to try to avoid spending time in Marshal,
    # which is a constant penalty that both clients have to pay
    @value = []
    @marshalled = Marshal.dump(@value)

    @servers = ['127.0.0.1:19122', 'localhost:19122']
    @key1 = "Short"
    @key2 = "Sym1-2-3::45"*8
    @key3 = "Long"*40
    @key4 = "Medium"*8
    # 5 and 6 are only used for multiget miss test
    @key5 = "Medium2"*8
    @key6 = "Long3"*40
    @counter = 'counter'
  end
  
  def test_benchmark
    memcached do
    
      Benchmark.bm(31) do |x|

        n = 2500

        @m = Dalli::Client.new(@servers)
        x.report("set:plain:dalli") do
          n.times do
            @m.set @key1, @marshalled, 0, :raw => true
            @m.set @key2, @marshalled, 0, :raw => true
            @m.set @key3, @marshalled, 0, :raw => true
            @m.set @key1, @marshalled, 0, :raw => true
            @m.set @key2, @marshalled, 0, :raw => true
            @m.set @key3, @marshalled, 0, :raw => true
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("setq:plain:dalli") do
          @m.multi do
            n.times do
              @m.set @key1, @marshalled, 0, :raw => true
              @m.set @key2, @marshalled, 0, :raw => true
              @m.set @key3, @marshalled, 0, :raw => true
              @m.set @key1, @marshalled, 0, :raw => true
              @m.set @key2, @marshalled, 0, :raw => true
              @m.set @key3, @marshalled, 0, :raw => true
            end
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("set:ruby:dalli") do
          n.times do
            @m.set @key1, @value
            @m.set @key2, @value
            @m.set @key3, @value
            @m.set @key1, @value
            @m.set @key2, @value
            @m.set @key3, @value
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("get:plain:dalli") do
          n.times do
            @m.get @key1, :raw => true
            @m.get @key2, :raw => true
            @m.get @key3, :raw => true
            @m.get @key1, :raw => true
            @m.get @key2, :raw => true
            @m.get @key3, :raw => true
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("get:ruby:dalli") do
          n.times do
            @m.get @key1
            @m.get @key2
            @m.get @key3
            @m.get @key1
            @m.get @key2
            @m.get @key3
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("multiget:ruby:dalli") do
          n.times do
            # We don't use the keys array because splat is slow
            @m.get_multi @key1, @key2, @key3, @key4, @key5, @key6
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("missing:ruby:dalli") do
          n.times do
            begin @m.delete @key1; rescue; end
            begin @m.get @key1; rescue; end
            begin @m.delete @key2; rescue; end
            begin @m.get @key2; rescue; end
            begin @m.delete @key3; rescue; end
            begin @m.get @key3; rescue; end
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("mixed:ruby:dalli") do
          n.times do
            @m.set @key1, @value
            @m.set @key2, @value
            @m.set @key3, @value
            @m.get @key1
            @m.get @key2
            @m.get @key3
            @m.set @key1, @value
            @m.get @key1
            @m.set @key2, @value
            @m.get @key2
            @m.set @key3, @value
            @m.get @key3
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("mixedq:ruby:dalli") do
          @m.multi do
            n.times do
              @m.set @key1, @value
              @m.set @key2, @value
              @m.set @key3, @value
              @m.get @key1
              @m.get @key2
              @m.get @key3
              @m.set @key1, @value
              @m.get @key1
              @m.set @key2, @value
              @m.replace @key2, @value
              @m.delete @key3
              @m.add @key3, @value
              @m.get @key2
              @m.set @key3, @value
              @m.get @key3
            end
          end
        end

        @m = Dalli::Client.new(@servers)
        x.report("incr:ruby:dalli") do
          n.times do
            @m.incr @counter, 1, 0, 1
          end
          n.times do
            @m.decr @counter, 1
          end

          assert_equal 0, @m.incr(@counter, 0)
        end

      end
    end

  end
end