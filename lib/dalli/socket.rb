# frozen_string_literal: true
require 'rbconfig'

module Dalli::Server::TCPSocketOptions
  def setsockopts(sock, options)
    sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true) if options[:keepalive]
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, options[:rcvbuf]) if options[:rcvbuf]
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, options[:sndbuf]) if options[:sndbuf]
  end
end

module Dalli::Server::KSocket
  module InstanceMethods
    def readfull(count)
      value = String.new('')
      begin
        while true
          value << read_nonblock(count - value.bytesize)
          break if value.bytesize == count
        end
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK
        if IO.select([self], nil, nil, options[:socket_timeout])
          retry
        else
          safe_options = options.reject{|k,v| [:username, :password].include? k}
          raise Timeout::Error, "IO timeout: #{safe_options.inspect}"
        end
      end
      value
    end

    def read_available
      value = String.new('')
      while true
        begin
          value << read_nonblock(8196)
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          break
        end
      end
      value
    end
  end

  def self.included(receiver)
    receiver.send(:attr_accessor, :options, :server)
    receiver.send(:include, InstanceMethods)
  end
end

class Dalli::Server::KSocket::TCP < TCPSocket
  extend Dalli::Server::TCPSocketOptions
  include Dalli::Server::KSocket

  def self.open(host, port, server, options = {})
    Timeout.timeout(options[:socket_timeout]) do
      sock = new(host, port)
      setsockopts(sock, options)
      sock.options = {:host => host, :port => port}.merge(options)
      sock.server = server
      sock
    end
  end
end

if RbConfig::CONFIG['host_os'] =~ /mingw|mswin/
  class Dalli::Server::KSocket::UNIX
    def initialize(*args)
      raise Dalli::DalliError, "Unix sockets are not supported on Windows platform."
    end
  end
else
  class Dalli::Server::KSocket::UNIX < UNIXSocket
    include Dalli::Server::KSocket

    def self.open(path, server, options = {})
      Timeout.timeout(options[:socket_timeout]) do
        sock = new(path)
        sock.options = {:path => path}.merge(options)
        sock.server = server
        sock
      end
    end
  end

end
