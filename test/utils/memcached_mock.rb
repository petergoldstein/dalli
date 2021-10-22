# frozen_string_literal: true

require 'tempfile'

##
# Utility for generating a mocked memcached instance.  The mocked instance
# takes a block, which defines the behavior of the socket.  Both TCP and
# UNIX domain sockets are supported.
##
module MemcachedMock
  UNIX_SOCKET_PATH = (f = Tempfile.new('dalli_test')
                      f.close
                      f.path)

  def self.start(port = 19_123)
    server = TCPServer.new('localhost', port)
    session = server.accept
    yield(session)
  end

  def self.start_unix(path = UNIX_SOCKET_PATH)
    begin
      File.delete(path)
    rescue Errno::ENOENT
      # Ignore file not found errors
    end
    server = UNIXServer.new(path)
    session = server.accept
    yield(session)
  end

  def self.delayed_start(port = 19_123, wait = 1)
    server = TCPServer.new('localhost', port)
    sleep wait
    yield(server)
  end
end
