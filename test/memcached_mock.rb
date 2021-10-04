# frozen_string_literal: true

require "socket"
require "tempfile"

$started = {}

module MemcachedMock
  UNIX_SOCKET_PATH = (f = Tempfile.new("dalli_test"); f.close; f.path)

  def self.start(port = 19123)
    server = TCPServer.new("localhost", port)
    session = server.accept
    yield(session)
  end

  def self.start_unix(path = UNIX_SOCKET_PATH)
    begin
      File.delete(path)
    rescue Errno::ENOENT
    end
    server = UNIXServer.new(path)
    session = server.accept
    yield(session)
  end

  def self.delayed_start(port = 19123, wait = 1)
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
    def memcached_mock(prc, meth = :start, meth_args = [])
      return unless supports_fork?
      begin
        pid = fork {
          trap("TERM") { exit }

          MemcachedMock.send(meth, *meth_args) do |*args|
            prc.call(*args)
          end
        }

        sleep 0.3 # Give time for the socket to start listening.
        yield
      ensure
        if pid
          Process.kill("TERM", pid)
          Process.wait(pid)
        end
      end
    end

    PATHS = %w[
      /usr/local/bin/
      /opt/local/bin/
      /usr/bin/
    ]

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

    def memcached_persistent(port = 21345, options = {})
      dc = start_and_flush_with_retry(port, "", options)
      yield dc, port if block_given?
    end

    def sasl_credentials
      {username: "testuser", password: "testtest"}
    end

    def sasl_env
      {
        "MEMCACHED_SASL_PWDB" => "#{File.dirname(__FILE__)}/sasl/sasldb",
        "SASL_CONF_PATH" => "#{File.dirname(__FILE__)}/sasl/memcached.conf"
      }
    end

    def memcached_sasl_persistent(port = 21397)
      dc = start_and_flush_with_retry(port, "-S", sasl_credentials)
      yield dc, port if block_given?
    end

    def memcached_ssl_persistent(port = 21397)
      generate_ssl_certificates

      ssl_context = OpenSSL::SSL::SSLContext.new
      ssl_context.ca_file = "/tmp/root.crt"
      ssl_context.ssl_version = :SSLv23
      ssl_context.verify_hostname = true
      ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER

      dc = start_and_flush_with_retry(port, "-Z -o ssl_chain_cert=/tmp/memcached.crt -o ssl_key=/tmp/memcached.key", {:ssl_context => ssl_context})
      yield dc, port if block_given?
    end

    private def generate_ssl_certificates
      require 'openssl'
      require 'openssl-extensions/all'

      root_key = OpenSSL::PKey::RSA.new 2048 # the CA's public/private key
      root_cert = OpenSSL::X509::Certificate.new
      root_cert.version = 2 # cf. RFC 5280 - to make it a "v3" certificate
      root_cert.subject = OpenSSL::X509::Name.parse "/CN=Dalli CA"
      root_cert.issuer = root_cert.subject # root CA's are "self-signed"
      root_cert.public_key = root_key.public_key
      root_cert.not_before = Time.now
      root_cert.not_after = root_cert.not_before + 2 * 365 * 24 * 60 * 60 # 2 years
      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = root_cert
      ef.issuer_certificate = root_cert
      root_cert.add_extension(ef.create_extension("basicConstraints","CA:TRUE",true))
      root_cert.add_extension(ef.create_extension("keyUsage","keyCertSign, cRLSign", true))
      root_cert.add_extension(ef.create_extension("subjectKeyIdentifier","hash",false))
      root_cert.sign(root_key, OpenSSL::Digest::SHA256.new)
      File.write("/tmp/root.key", root_key)
      File.write("/tmp/root.crt", root_cert)

      key = OpenSSL::PKey::RSA.new 2048
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.subject = OpenSSL::X509::Name.parse "/CN=localhost"
      cert.issuer = root_cert.subject # root CA is the issuer
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = cert.not_before + 2 * 365 * 24 * 60 * 60 # 2 years
      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = root_cert
      cert.add_extension(ef.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1", false))
      cert.add_extension(ef.create_extension("keyUsage","digitalSignature", true))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier","hash",false))
      cert.sign(root_key, OpenSSL::Digest::SHA256.new)

      File.write("/tmp/memcached.key", key)
      File.write("/tmp/memcached.crt", cert)
    end

    def start_and_flush_with_retry(port, args = "", client_options = {})
      dc = nil
      retry_count = 0
      while dc.nil?
        begin
          dc = start_and_flush(port, args, client_options, (retry_count == 0))
        rescue => e
          $started[port] = nil
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

    def memcached(port, args = "", client_options = {})
      dc = start_and_flush_with_retry(port, args, client_options)
      yield dc, port if block_given?
      memcached_kill(port)
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

      $started[port] ||= begin
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

    def supports_fork?
      Process.respond_to?(:fork)
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
