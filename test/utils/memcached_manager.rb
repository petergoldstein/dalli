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
  MEMCACHED_VERSION_CMD = "#{MEMCACHED_CMD} -h | head -1".freeze
  MEMCACHED_VERSION_REGEXP = /^memcached (\d\.\d\.\d+)/
  MEMCACHED_MIN_VERSION = ::Dalli::MIN_SUPPORTED_MEMCACHED_VERSION

  # Versions are compared as Gem::Version, never as strings.  Lexically
  # '1.6.9' > '1.6.27', which would let a server below the floor through, and a
  # strict '>' would reject the floor version itself.
  def self.at_least_version?(candidate, minimum)
    Gem::Version.new(candidate) >= Gem::Version.new(minimum)
  end

  @running_pids = {}

  def self.start_and_flush_with_retry(port_or_socket, args = '', client_options = {})
    retry_count = 0
    loop do
      return start_and_flush(port_or_socket, args, client_options, flush: retry_count.zero?)
    rescue StandardError => e
      MemcachedManager.failed_start(port_or_socket)
      retry_count += 1
      raise e if retry_count >= 3
    end
  end

  def self.start_and_flush(port_or_socket, args = '', client_options = {}, flush: true)
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

    confirm_stopped(port_or_socket)
  end

  def self.kill_and_wait(pid)
    Process.kill('TERM', pid)
    Process.wait(pid)
  end

  # Tests that kill a server then assert on its absence depend on the port
  # actually being free.  Reaping the pid is not on its own proof of that -- if
  # some other process still holds the port, the client keeps getting answers
  # and the assertion fails somewhere far from the cause.  Fail here instead,
  # where the reason is obvious.
  STOP_TIMEOUT_SECONDS = 5
  def self.confirm_stopped(port_or_socket)
    port = port_or_socket.to_i
    return if port.zero? # UNIX socket; memcached removes the socket file itself

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_TIMEOUT_SECONDS
    loop do
      return unless port_accepting?(port)

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "memcached on port #{port} still accepting connections " \
              "#{STOP_TIMEOUT_SECONDS}s after being stopped"
      end

      sleep 0.05
    end
  end

  def self.port_accepting?(port)
    TCPSocket.new('127.0.0.1', port).close
    true
  rescue SystemCallError
    false
  end

  # A start that raised may still have spawned a process holding the port.
  # Dropping the pid without killing it leaked that process: the port stayed
  # bound, subsequent kills targeted a pid that no longer owned it, and tests
  # asserting a server was gone found a live one.
  def self.failed_start(port_or_socket)
    pid = @running_pids.delete(port_or_socket)
    return unless pid

    begin
      kill_and_wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
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

  def self.version
    return @version unless @version.nil?

    cmd
    @version
  end

  # determine_cmd refuses to return a binary below MEMCACHED_MIN_VERSION and
  # raises when it finds none, so anything reachable from here is already known
  # to be a supported version.  Guards that re-checked lower thresholds (the
  # meta protocol at 1.6, the meta delete CAS fix at 1.6.13) could no longer
  # fire once the floor moved to 1.6.27 and have been removed.
  def self.supported_protocols
    %i[meta]
  end

  def self.cmd_with_args(port_or_socket, args)
    socket_arg, key = parse_port_or_socket(port_or_socket)
    ["#{cmd} #{args} #{socket_arg}", key]
  end

  def self.determine_cmd
    PATH_PREFIXES.each do |prefix|
      output = `#{prefix}#{MEMCACHED_VERSION_CMD}`.strip
      next unless output && output =~ MEMCACHED_VERSION_REGEXP

      version = Regexp.last_match(1)
      next unless at_least_version?(version, MEMCACHED_MIN_VERSION)

      @version = version
      puts "Found #{output} in #{prefix.empty? ? 'PATH' : prefix}"
      return "#{prefix}#{MEMCACHED_CMD}"
    end

    raise Errno::ENOENT, "Unable to find memcached #{MEMCACHED_MIN_VERSION}+ locally"
  end
end
