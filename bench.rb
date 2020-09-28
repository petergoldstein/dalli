# frozen_string_literal: true

require 'ruby-prof'
require "benchmark"
require 'dalli'

def profile(&block)
  return yield unless ENV["PROFILE"]

  prof = RubyProf::Profile.new
  result = prof.profile(&block)
  rep = RubyProf::GraphHtmlPrinter.new(result)
  rep.print(File.new("profile.html", "w"), min_percent: 1)
end

puts "Testing #{Dalli::VERSION} with #{RUBY_DESCRIPTION}"

class Bencher
  def initialize
    # We'll use a simple @value to try to avoid spending time in Marshal,
    # which is a constant penalty that both clients have to pay
    @started = {}
    @value = []
    @marshalled = Marshal.dump(@value)

    @port = 23417
    @servers = ["127.0.0.1:#{@port}", "localhost:#{@port}"]
    @key1 = "Short"
    @key2 = "Sym1-2-3::45" * 8
    @key3 = "Long" * 40
    @key4 = "Medium" * 8
    # 5 and 6 are only used for multiget miss test
    @key5 = "Medium2" * 8
    @key6 = "Long3" * 40
    @counter = "counter"
  end

  def call
    memcached(@port) do
      profile do
        Benchmark.bm(37) do |x|
          n = 2500

          @m = Dalli::Client.new(@servers)
          x.report("set:plain:dalli") do
            n.times do
              @m.set @key1, @marshalled, 0, raw: true
              @m.set @key2, @marshalled, 0, raw: true
              @m.set @key3, @marshalled, 0, raw: true
              @m.set @key1, @marshalled, 0, raw: true
              @m.set @key2, @marshalled, 0, raw: true
              @m.set @key3, @marshalled, 0, raw: true
            end
          end

          @m = Dalli::Client.new(@servers)
          x.report("setq:plain:dalli") do
            @m.multi do
              n.times do
                @m.set @key1, @marshalled, 0, raw: true
                @m.set @key2, @marshalled, 0, raw: true
                @m.set @key3, @marshalled, 0, raw: true
                @m.set @key1, @marshalled, 0, raw: true
                @m.set @key2, @marshalled, 0, raw: true
                @m.set @key3, @marshalled, 0, raw: true
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
              @m.get @key1, raw: true
              @m.get @key2, raw: true
              @m.get @key3, raw: true
              @m.get @key1, raw: true
              @m.get @key2, raw: true
              @m.get @key3, raw: true
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
            counter = "foocount"
            n.times do
              @m.incr counter, 1, 0, 1
            end
            n.times do
              @m.decr counter, 1
            end

            result = @m.incr(counter, 0)
            raise result if result != 0
          end
        end
      end
    end
  end

  def memcached(port, args = "", client_options = {})
    dc = start_and_flush_with_retry(port, args, client_options)
    yield dc, port if block_given?
    memcached_kill(port)
  end

  def memcached_kill(port)
    pid = @started.delete(port)
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ECHILD, Errno::ESRCH => e
        puts e.inspect
      end
    end
  end
  def start_and_flush_with_retry(port, args = "", client_options = {})
    dc = nil
    retry_count = 0
    while dc.nil?
      begin
        dc = start_and_flush(port, args, client_options, (retry_count == 0))
      rescue => e
        @started[port] = nil
        retry_count += 1
        raise e if retry_count >= 3
      end
    end
    dc
  end

  def start_and_flush(port, args = "", client_options = {}, flush = true)
    memcached_server(port, args)
    dc = if port.to_i == 0
      # unix socket
      Dalli::Client.new(port, client_options)
    else
      Dalli::Client.new(["localhost:#{port}", "127.0.0.1:#{port}"], client_options)
    end
    dc.flush_all if flush
    dc
  end

  def memcached_server(port, args = "")
    Memcached.path ||= find_memcached
    if port.to_i == 0
      # unix socket
      port_socket_arg = "-s"
      begin
        File.delete(port)
      rescue Errno::ENOENT
      end
    else
      port_socket_arg = "-p"
      port = port.to_i
    end

    cmd = "#{Memcached.path}memcached #{args} #{port_socket_arg} #{port}"

    @started[port] ||= begin
      pid = IO.popen(cmd).pid
      at_exit do
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ECHILD, Errno::ESRCH
      end
      wait_time = 0.1
      sleep wait_time
      pid
    end
  end

  def find_memcached
    output = `memcached -h | head -1`.strip
    if output && output =~ /^memcached (\d.\d.\d+)/ && $1 > "1.4"
      return (puts "Found #{output} in PATH"; "")
    end
    PATHS.each do |path|
      output = `memcached -h | head -1`.strip
      if output && output =~ /^memcached (\d\.\d\.\d+)/ && $1 > "1.4"
        return (puts "Found #{output} in #{path}"; path)
      end
    end

    raise Errno::ENOENT, "Unable to find memcached 1.4+ locally"
  end



end

module Memcached
  class << self
    attr_accessor :path
  end
end

Bencher.new.call
