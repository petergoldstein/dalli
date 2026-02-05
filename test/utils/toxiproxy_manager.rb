# frozen_string_literal: true

require 'net/http'
require 'minitest'

##
# Utility module for managing the toxiproxy server for testing network failures.
##
module ToxiproxyManager
  TOXIPROXY_VERSION = 'v2.4.0'
  TOXIPROXY_PORT = 8474
  TOXIPROXY_BIN = File.expand_path('../../bin/toxiproxy-server', __dir__)
  TOXIPROXY_MEMCACHED_PORT = 21_347
  TOXIPROXY_UPSTREAM_PORT = 21_348

  @pid = nil

  def self.start
    return if running?

    ensure_binary_exists
    start_server
  end

  def self.running?
    uri = URI("http://127.0.0.1:#{TOXIPROXY_PORT}/version")
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPSuccess)
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
    false
  end

  def self.ensure_binary_exists
    return if File.executable?(TOXIPROXY_BIN)

    download_binary
  end

  def self.download_binary
    download_type = case RUBY_PLATFORM
                    when /darwin/
                      'darwin-amd64'
                    when /linux/
                      'linux-amd64'
                    else
                      raise "Unsupported platform: #{RUBY_PLATFORM}"
                    end

    url = "https://github.com/Shopify/toxiproxy/releases/download/#{TOXIPROXY_VERSION}/toxiproxy-server-#{download_type}"
    puts "[toxiproxy] Downloading toxiproxy for #{download_type}..."

    bin_dir = File.dirname(TOXIPROXY_BIN)
    FileUtils.mkdir_p(bin_dir)

    system("curl --silent -L #{url} -o #{TOXIPROXY_BIN}")
    FileUtils.chmod(0o755, TOXIPROXY_BIN)
  end

  def self.start_server
    puts '[toxiproxy] Starting toxiproxy server...'
    @pid = spawn(TOXIPROXY_BIN, %i[out err] => File::NULL)

    # Use Minitest.after_run instead of at_exit to avoid being triggered by forked children
    Minitest.after_run do
      ToxiproxyManager.stop
    end

    # Wait for server to be ready
    20.times do
      break if running?

      sleep 0.1
    end

    raise 'Failed to start toxiproxy server' unless running?

    puts '[toxiproxy] Server started successfully'
  end

  def self.stop
    return unless @pid

    begin
      Process.kill('TERM', @pid)
      Process.wait(@pid)
    rescue Errno::ECHILD, Errno::ESRCH
      # Process already terminated
    end
    @pid = nil
  end
end
