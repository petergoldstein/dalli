require "socket"

module MemcachedMock
  def self.start(port=22122, &block)
    server = TCPServer.new("localhost", port)
    session = server.accept
    block.call session
  end

  def self.delayed_start(port=22122, wait=1, &block)
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
  end
end