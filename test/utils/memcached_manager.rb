# frozen_string_literal: true

##
# Utility module for spinning up memcached instances locally, and generating a corresponding
# Dalli::Client to access the local instance.  Supports access via TCP and UNIX domain socket.
##
module MemcachedManager
  # TODO: This is all UNIX specific.  To support
  # running CI on Windows we'll need to conditionally
  # define a Windows equivalent
  PATH_PREFIXES = [
    '',
    '/usr/local/bin/',
    '/opt/local/bin/',
    '/usr/bin/'
  ].freeze

  MEMCACHED_CMD = 'memcached'
  MEMCACHED_VERSION_CMD = "#{MEMCACHED_CMD} -h | head -1"
  MEMCACHED_VERSION_REGEXP = /^memcached (\d\.\d\.\d+)/.freeze
  MEMCACHED_MIN_MAJOR_VERSION = '1.4'

  @running_pids = {}

  def self.start_and_flush_with_retry(port_or_socket, args = '', client_options = {})
    retry_count = 0
    loop do
      return start_and_flush(port_or_socket, args, client_options, retry_count.zero?)
    rescue StandardError => e
      MemcachedManager.failed_start(port_or_socket)
      retry_count += 1
      raise e if retry_count >= 3
    end
  end

  def self.start_and_flush(port_or_socket, args = '', client_options = {}, flush = true)
    MemcachedManager.start(port_or_socket, args)
    dc = client_for_port_or_socket(port_or_socket, client_options)
    dc.flush_all if flush
    dc
  end

  def self.client_for_port_or_socket(port_or_socket, client_options)
    is_unix = port_or_socket.to_i.zero?
    servers_arg = is_unix ? port_or_socket : ["localhost:#{port_or_socket}", "127.0.0.1:#{port_or_socket}"]
    Dalli::Client.new(servers_arg, client_options)
  end

  def self.start(port_or_socket, args)
    cmd_with_args, key = cmd_with_args(port_or_socket, args)

    @running_pids[key] ||= begin
      pid = IO.popen(cmd_with_args).pid
      at_exit do
        kill_and_wait(pid)
      rescue Errno::ECHILD, Errno::ESRCH
        # Ignore errors
      end
      sleep 0.1
      pid
    end
  end

  def self.stop(port_or_socket)
    pid = @running_pids.delete(port_or_socket)
    return unless pid

    begin
      kill_and_wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH => e
      puts e.inspect
    end
  end

  def self.kill_and_wait(pid)
    Process.kill('TERM', pid)
    Process.wait(pid)
  end

  def self.failed_start(port_or_socket)
    @running_pids[port_or_socket] = nil
  end

  def self.parse_port_or_socket(port)
    return "-p #{port}", port.to_i unless port.to_i.zero?

    # unix socket
    begin
      File.delete(port)
    rescue Errno::ENOENT
      # Ignore errors
    end
    ["-s #{port}", port]
  end

  def self.cmd
    @cmd ||= determine_cmd
  end

  def self.cmd_with_args(port_or_socket, args)
    socket_arg, key = parse_port_or_socket(port_or_socket)
    ["#{cmd} #{args} #{socket_arg}", key]
  end

  def self.determine_cmd
    PATH_PREFIXES.each do |prefix|
      output = `#{prefix}#{MEMCACHED_VERSION_CMD}`.strip
      next unless output && output =~ MEMCACHED_VERSION_REGEXP
      next unless Regexp.last_match(1) > MEMCACHED_MIN_MAJOR_VERSION

      puts "Found #{output} in #{prefix.empty? ? 'PATH' : prefix}"
      return "#{prefix}#{MEMCACHED_CMD}"
    end

    raise Errno::ENOENT, "Unable to find memcached #{MEMCACHED_MIN_MAJOR_VERSION}+ locally"
  end
end
