require "socket"
require "tempfile"

$started = {}

module MemcachedMock
  UNIX_SOCKET_PATH = (f = Tempfile.new('dalli_test'); f.close; f.path)

  def self.start(port=19123)
    server = TCPServer.new("localhost", port)
    session = server.accept
    yield(session)
  end

  def self.start_unix(path=UNIX_SOCKET_PATH)
    begin
      File.delete(path)
    rescue Errno::ENOENT
    end
    server = UNIXServer.new(path)
    session = server.accept
    yield(session)
  end

  def self.delayed_start(port=19123, wait=1)
    server = TCPServer.new("localhost", port)
    sleep wait
    yield(server)
  end

  module Helper
    # Forks the current process and starts a new mock Memcached server on
    # port 22122.
    #
    #     memcached_mock(lambda {|sock| socket.write('123') }) do
    #       assert_equal "PONG", Dalli::Client.new('localhost:22122').get('abc')
    #     end
    #
    def memcached_mock(proc, meth=:start, meth_args=[])
      return unless supports_fork?
      begin
        pid = fork do
          trap("TERM") { exit }

          MemcachedMock.send(meth, *meth_args) do |*args|
            proc.call(*args)
          end
        end

        sleep 0.3 # Give time for the socket to start listening.
        yield
      ensure
        if pid
          Process.kill("TERM", pid)
          Process.wait(pid)
        end
      end
    end

    PATHS = %w(
      /usr/local/bin/
      /opt/local/bin/
      /usr/bin/
    )

    def find_memcached
      output = `memcached -h | head -1`.strip
      if output && output =~ /^memcached (\d.\d.\d+)/ && $1 > '1.4'
        return (puts "Found #{output} in PATH"; '')
      end
      PATHS.each do |path|
        output = `memcached -h | head -1`.strip
        if output && output =~ /^memcached (\d\.\d\.\d+)/ && $1 > '1.4'
          return (puts "Found #{output} in #{path}"; path)
        end
      end

      raise Errno::ENOENT, "Unable to find memcached 1.4+ locally"
    end

    def memcached_persistent(port=21345)
      dc = start_and_flush_with_retry(port, '', {})
      yield dc, port if block_given?
    end

    def sasl_credentials
      { :username => 'testuser', :password => 'testtest' }
    end

    def sasl_env
      {
        'MEMCACHED_SASL_PWDB' => "#{File.dirname(__FILE__)}/sasl/sasldb",
        'SASL_CONF_PATH' => "#{File.dirname(__FILE__)}/sasl/memcached.conf"
      }
    end

    def memcached_sasl_persistent(port=21397)
      dc = start_and_flush_with_retry(port, '-S', sasl_credentials)
      yield dc, port if block_given?
    end

    def memcached_cas_persistent(port = 25662)
      require 'dalli/cas/client'
      dc = start_and_flush_with_retry(port)
      yield dc, port if block_given?
    end


    def memcached_low_mem_persistent(port = 19128)
      dc = start_and_flush_with_retry(port, '-m 1 -M')
      yield dc, port if block_given?
    end

    def start_and_flush_with_retry(port, args = '', client_options = {})
      dc = nil
      retry_count = 0
      while dc.nil? do
        begin
          dc = start_and_flush(port, args, client_options, (retry_count == 0))
        rescue StandardError => e
          $started[port] = nil
          retry_count += 1
          raise e if retry_count >= 3
        end
      end
      dc
    end

    def start_and_flush(port, args = '', client_options = {}, flush = true)
      memcached_server(port, args)
      if "#{port}" =~ /\A\//
        # unix socket
        dc = Dalli::Client.new(port, client_options)
      else
        dc = Dalli::Client.new(["localhost:#{port}", "127.0.0.1:#{port}"], client_options)
      end
      dc.flush_all if flush
      dc
    end

    def memcached(port, args='', client_options={})
      dc = start_and_flush_with_retry(port, args, client_options)
      yield dc, port if block_given?
      memcached_kill(port)
    end

    def memcached_server(port, args='')
      Memcached.path ||= find_memcached
      if "#{port}" =~ /\A\//
        # unix socket
        port_socket_arg = '-s'
        begin
          File.delete(port)
        rescue Errno::ENOENT
        end
      else
        port_socket_arg = '-p'
        port = port.to_i
      end

      cmd = "#{Memcached.path}memcached #{args} #{port_socket_arg} #{port}"

      $started[port] ||= begin
        pid = IO.popen(cmd).pid
        at_exit do
          begin
            Process.kill("TERM", pid)
            Process.wait(pid)
          rescue Errno::ECHILD, Errno::ESRCH
          end
        end
        wait_time = (args && args =~ /\-S/) ? 0.1 : 0.1
        sleep wait_time
        pid
      end
    end

    def supports_fork?
      !defined?(RUBY_ENGINE) || RUBY_ENGINE != 'jruby'
    end

    def memcached_kill(port)
      pid = $started.delete(port)
      if pid
        begin
          Process.kill("TERM", pid)
          Process.wait(pid)
        rescue Errno::ECHILD, Errno::ESRCH => e
          puts e.inspect
        end
      end
    end

  end
end

module Memcached
  class << self
    attr_accessor :path
  end
end
