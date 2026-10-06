# frozen_string_literal: true

require 'English'
require 'socket'
require 'timeout'

require 'dalli/pid_cache'

module Dalli
  module Protocol
    ##
    # Manages the socket connection to the server, including ensuring liveness
    # and retries.
    ##
    class ConnectionManager
      DEFAULTS = {
        # seconds between trying to contact a remote server
        down_retry_delay: 30,
        # connect/read/write timeout for socket operations
        socket_timeout: 1,
        # times a socket operation may fail before considering the server dead
        socket_max_failures: 2,
        # amount of time to sleep between retries when a failure occurs
        socket_failure_delay: 0.1,
        # Set keepalive
        keepalive: true
      }.freeze

      attr_accessor :hostname, :port, :socket_type, :options
      attr_reader :sock

      def initialize(hostname, port, socket_type, client_options)
        @hostname = hostname
        @port = port
        @socket_type = socket_type
        @options = DEFAULTS.merge(client_options)
        @request_in_progress = false
        @sock = nil
        @pid = nil
        @write_buffer = []
        @write_buffer_bytes = 0

        @fail_count = 0
        reset_down_info
      end

      def name
        if socket_type == :unix
          hostname
        else
          "#{hostname}:#{port}"
        end
      end

      def establish_connection
        Dalli.logger.debug { "Dalli::Server#connect #{name}" }

        @sock = memcached_socket
        # Writes are buffered in @write_buffer instead; see WRITE_BUFFER_FLUSH_BYTES
        @sock.sync = true
        @pid = Process.pid
        @request_in_progress = false
      rescue SystemCallError, *TIMEOUT_ERRORS, EOFError, SocketError => e
        # SocketError = DNS resolution failure
        error_on_request!(e)
      end

      def reconnect_down_server?
        return true unless @last_down_at

        time_to_next_reconnect = @last_down_at + options[:down_retry_delay] - Time.now
        return true unless time_to_next_reconnect.positive?

        Dalli.logger.debug do
          format('down_retry_delay not reached for %<name>s (%<time>.3f seconds left)', name: name,
                                                                                        time: time_to_next_reconnect)
        end
        false
      end

      def up!
        log_up_detected
        reset_down_info
      end

      # Marks the server instance as down.  Updates the down_at state
      # and raises an Dalli::NetworkError that includes the underlying
      # error in the message.  Calls close to clean up socket state
      def down!
        close
        log_down_detected
        # Once down_retry_delay passes, the server gets a full set of attempts
        @fail_count = 0

        @error = $ERROR_INFO&.class&.name
        @msg ||= $ERROR_INFO&.message
        raise_down_error
      end

      def raise_down_error
        raise Dalli::NetworkError, "#{name} is down: #{@error} #{@msg}"
      end

      def socket_timeout
        @socket_timeout ||= @options[:socket_timeout]
      end

      def confirm_ready!
        close if request_in_progress?
        reconnect_on_fork if fork_detected?
      end

      def confirm_in_progress!
        raise '[Dalli] No request in progress. This may be a bug in Dalli.' unless request_in_progress?

        reconnect_on_fork if fork_detected?
      end

      def close
        return unless @sock

        begin
          close_socket
        rescue StandardError
          nil
        end
        @sock = nil
        @pid = nil
        discard_write_buffer
        abort_request!
      end

      # A forked child shares the parent's connection, so it closes only its
      # own file descriptor. Closing the TLS socket itself would send
      # close_notify and end the parent's TLS session.
      def close_socket
        fork_detected? ? @sock.to_io.close : @sock.close
      end

      def connected?
        !@sock.nil?
      end

      def request_in_progress?
        @request_in_progress
      end

      def start_request!
        raise '[Dalli] Request already in progress. This may be a bug in Dalli.' if @request_in_progress

        @request_in_progress = true
      end

      def finish_request!
        raise '[Dalli] No request in progress. This may be a bug in Dalli.' unless @request_in_progress

        @request_in_progress = false
        # A completed request is what proves the server healthy again, so the
        # failure count resets here rather than on reconnect: a server that
        # accepts connections but never answers would otherwise reset it on
        # every retry and never reach socket_max_failures.
        @fail_count = 0
      end

      def abort_request!
        @request_in_progress = false
      end

      def read_line
        flush_write_buffer
        data = @sock.gets("\r\n")
        error_on_request!('EOF in read_line') if data.nil?
        data
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
        error_on_request!(e)
      end

      # memcached can't store an item larger than 1 GiB (its -I maximum), so a
      # reply claiming more (or a negative size) is malformed or hostile.
      # Reading allocates the full count up front, so check before reading.
      MAX_READ_BYTES = (1024 * 1024 * 1024) + 2 # plus the value's trailing "\r\n"

      def check_read_size!(count)
        return if count.between?(0, MAX_READ_BYTES)

        raise Dalli::DalliError, "Reply size #{count} from #{name} is out of range"
      end

      def read(count)
        check_read_size!(count)
        flush_write_buffer
        @sock.readfull(count)
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
        error_on_request!(e)
      end

      # Requests are buffered here rather than in the socket's own IO buffer
      # (the socket is sync). Ruby flushes an IO's write buffer when any process
      # holding it closes or finalizes the IO, so after a fork a child could
      # send bytes the parent had buffered but not sent yet: a quiet write would
      # run twice, or the parent's replies would shift onto the wrong requests.
      # A forked child discards this buffer instead. Like IO's own buffer, it
      # is sent once it grows past this size, or when a reply is read.
      WRITE_BUFFER_FLUSH_BYTES = 64 * 1024

      def write(bytes)
        @write_buffer << bytes
        @write_buffer_bytes += bytes.bytesize
        flush_write_buffer if @write_buffer_bytes >= WRITE_BUFFER_FLUSH_BYTES
        bytes.bytesize
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, IOError => e
        error_on_request!(e)
      end

      def flush
        flush_write_buffer
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, IOError => e
        error_on_request!(e)
      end

      # Non-blocking read.  Here to support the operation
      # of the get_multi operation
      def read_nonblock
        flush_write_buffer
        @sock.read_available
      end

      def max_allowed_failures
        @max_allowed_failures ||= @options[:socket_max_failures] || 2
      end

      def error_on_request!(err_or_string)
        log_warn_message(err_or_string)

        @fail_count += 1
        if @fail_count >= max_allowed_failures
          down!
        else
          # Closes the existing socket, setting up for a reconnect
          # on next request
          reconnect!('Socket operation failed, retrying...')
        end
      end

      def reconnect!(message)
        close
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
        raise Dalli::RetryableNetworkError, message
      end

      # Called on connect. Deliberately leaves @fail_count alone; see
      # finish_request!.
      def reset_down_info
        @down_at = nil
        @last_down_at = nil
        @msg = nil
        @error = nil
      end

      def memcached_socket
        if socket_type == :unix
          Dalli::Socket::UNIX.open(hostname, options)
        else
          Dalli::Socket::TCP.open(hostname, port, options)
        end
      end

      def log_warn_message(err_or_string)
        Dalli.logger.warn do
          detail = err_or_string.is_a?(String) ? err_or_string : "#{err_or_string.class}: #{err_or_string.message}"
          "#{name} failed (count: #{@fail_count}) #{detail}"
        end
      end

      def reconnect_on_fork
        message = 'Fork detected, re-connecting child process...'
        Dalli.logger.info { message }
        # Drops anything the parent had buffered, closes the inherited socket
        # without touching the parent's connection, and reconnects immediately
        close
        establish_connection
      end

      def fork_detected?
        # Process.pid rather than PIDCache: PIDCache is refreshed by a
        # Process._fork hook, and another library's fork hook (such as
        # connection_pool closing its connections) can run in the child before
        # it, which would close the parent's TLS session as if it were ours.
        @pid && @pid != Process.pid
      end

      def log_down_detected
        @last_down_at = Time.now

        if @down_at
          time = Time.now - @down_at
          Dalli.logger.debug { format('%<name>s is still down (for %<time>.3f seconds now)', name: name, time: time) }
        else
          @down_at = @last_down_at
          Dalli.logger.warn("#{name} is down")
        end
      end

      def log_up_detected
        return unless @down_at

        time = Time.now - @down_at
        Dalli.logger.warn { format('%<name>s is back (downtime was %<time>.3f seconds)', name: name, time: time) }
      end

      private

      # One write per flush. A TLS socket sends each argument of
      # write(*parts) as its own record and system call, so the parts are
      # joined first.
      def flush_write_buffer
        return if @write_buffer.empty?

        @sock.write(@write_buffer.size == 1 ? @write_buffer.first : joined_write_buffer)
        discard_write_buffer
      end

      # Joined as bytes: requests can mix UTF-8 and binary strings, which
      # String#<< refuses to combine when both hold non-ASCII bytes
      if String.method_defined?(:append_as_bytes)
        def joined_write_buffer
          out = String.new(capacity: @write_buffer_bytes, encoding: Encoding::BINARY)
          @write_buffer.each { |part| out.append_as_bytes(part) }
          out
        end
      else
        def joined_write_buffer
          out = String.new(capacity: @write_buffer_bytes, encoding: Encoding::BINARY)
          @write_buffer.each { |part| out << part.b }
          out
        end
      end

      def discard_write_buffer
        @write_buffer.clear
        @write_buffer_bytes = 0
      end
    end
  end
end
