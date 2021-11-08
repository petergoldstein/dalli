# frozen_string_literal: true

require 'socket'
require_relative '../utils/certificate_generator'
require_relative '../utils/memcached_manager'
require_relative '../utils/memcached_mock'

module Memcached
  module Helper
    # Forks the current process and starts a new mock Memcached server on
    # port 22122.
    #
    #     memcached_mock(lambda {|sock| socket.write('123') }) do
    #       assert_equal "PONG", Dalli::Client.new('localhost:22122').get('abc')
    #     end
    #
    def memcached_mock(prc, meth = :start, meth_args = [])
      return unless supports_fork?

      begin
        pid = fork_mock_process(prc, meth, meth_args)
        sleep 0.3 # Give time for the socket to start listening.
        yield
      ensure
        kill_process(pid)
      end
    end

    # Launches a memcached process with the specified arguments.  Takes
    # a block to which an initialized Dalli::Client and the port_or_socket
    # is passed.
    #
    # port_or_socket - If numeric or numeric string, treated as a TCP port
    #                  on localhost.  If not, treated as a UNIX domain socket
    # args - Command line args passed to the memcached invocation
    # client_options - Options passed to the Dalli::Client on initialization
    # terminate_process - whether to terminate the memcached process on
    #                     exiting the block
    def memcached(port_or_socket, args = '', client_options = {}, terminate_process: true)
      dc = MemcachedManager.start_and_flush_with_retry(port_or_socket, args, client_options)
      yield dc, port_or_socket if block_given?
      memcached_kill(port_or_socket) if terminate_process
    end

    # Launches a memcached process using the memcached method in this module,
    # but sets terminate_process to false ensuring that the process persists
    # past execution of the block argument.
    def memcached_persistent(port_or_socket = 21_345, args = '', client_options = {}, &block)
      memcached(port_or_socket, args, client_options, terminate_process: false, &block)
    end

    # Launches a persistent memcached process, configured to use SSL
    def memcached_ssl_persistent(port_or_socket = 21_397, &block)
      CertificateGenerator.generate
      memcached_persistent(port_or_socket,
                           CertificateGenerator.ssl_args,
                           { ssl_context: CertificateGenerator.ssl_context },
                           &block)
    end

    # Kills the memcached process that was launched using this helper on hte
    # specified port_or_socket.
    def memcached_kill(port_or_socket)
      MemcachedManager.stop(port_or_socket)
    end

    # Launches a persistent memcached process, configured to use SASL authentication
    def memcached_sasl_persistent(port_or_socket = 21_397, &block)
      memcached_persistent(port_or_socket, '-S', sasl_credentials, &block)
    end

    # The SASL credentials used for the test SASL server
    def sasl_credentials
      { username: 'testuser', password: 'testtest' }
    end

    private

    def fork_mock_process(prc, meth, meth_args)
      fork do
        trap('TERM') { exit }
        MemcachedMock.send(meth, *meth_args) { |*args| prc.call(*args) }
      end
    end

    def kill_process(pid)
      return unless pid

      Process.kill('TERM', pid)
      Process.wait(pid)
    end

    def supports_fork?
      Process.respond_to?(:fork)
    end
  end
end
