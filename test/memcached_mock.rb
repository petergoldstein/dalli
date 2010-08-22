require "socket"
require 'open4'

module MemcachedMock
  def self.start(port=19123, &block)
    server = TCPServer.new("localhost", port)
    session = server.accept
    block.call session
  end

  def self.delayed_start(port=19123, wait=1, &block)
    server = TCPServer.new("localhost", port)
    sleep wait
#    session = server.accept
    block.call server
  end

  module Helper
    # Forks the current process and starts a new mock Memcached server on
    # port 22122.
    #
    #     memcached_mock(lambda {|sock| socket.write('123') }) do
    #       assert_equal "PONG", Dalli::Client.new('localhost:22122').get('abc')
    #     end
    #
    def memcached_mock(proc, meth = :start)
      begin
        pid = fork do
          trap("TERM") { exit }

          MemcachedMock.send(meth) do |*args|
            proc.call(*args)
          end
        end

        sleep 0.5 # Give time for the socket to start listening.
        yield
      ensure
        if pid
          Process.kill("TERM", pid)
          Process.wait(pid)
        end
      end
    end

    def memcached
      if !Memcached.started
        begin
          puts "Starting"
          Memcached.started = true
          (Memcached.pid, _, _, _) = Open4.open4('/usr/local/bin/memcached -p 19122')
          at_exit do
            Process.kill("TERM", Memcached.pid)
            Process.wait(Memcached.pid)
          end
          sleep 0.1
        rescue Errno::ENOENT
          puts "Skipping live test as I couldn't start memcached on port 19122.\nInstall memcached 1.4 and ensure it is in the PATH."
        end
      end

      if Memcached.started && Memcached.pid && block_given?
        yield
      end
      Memcached.started
    end
  end
end

module Memcached
  class << self
    attr_accessor :started
    attr_accessor :pid
  end
end