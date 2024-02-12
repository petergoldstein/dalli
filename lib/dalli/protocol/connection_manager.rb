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
        @pid = PIDCache.pid
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
        close_on_fork if fork_detected?
      end

      def confirm_in_progress!
        raise '[Dalli] No request in progress. This may be a bug in Dalli.' unless request_in_progress?

        close_on_fork if fork_detected?
      end

      def close
        return unless @sock

        begin
          @sock.close
        rescue StandardError
          nil
        end
        @sock = nil
        @pid = nil
        abort_request!
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
      end

      def abort_request!
        @request_in_progress = false
      end

      def read_line
        data = @sock.gets("\r\n")
        error_on_request!('EOF in read_line') if data.nil?
        data
      rescue SystemCallError, *TIMEOUT_ERRORS, EOFError => e
        error_on_request!(e)
      end

      def read(count)
        @sock.readfull(count)
      rescue SystemCallError, *TIMEOUT_ERRORS, EOFError => e
        error_on_request!(e)
      end

      def write(bytes)
        @sock.write(bytes)
      rescue SystemCallError, *TIMEOUT_ERRORS => e
        error_on_request!(e)
      end

      # Non-blocking read.  Here to support the operation
      # of the get_multi operation
      def read_nonblock
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
        raise Dalli::NetworkError, message
      end

      def reset_down_info
        @fail_count = 0
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
        detail = err_or_string.is_a?(String) ? err_or_string : "#{err_or_string.class}: #{err_or_string.message}"
        Dalli.logger.warn do
          detail = err_or_string.is_a?(String) ? err_or_string : "#{err_or_string.class}: #{err_or_string.message}"
          "#{name} failed (count: #{@fail_count}) #{detail}"
        end
      end

      def close_on_fork
        message = 'Fork detected, re-connecting child process...'
        Dalli.logger.info { message }
        # Close socket on a fork, setting us up for reconnect
        # on next request.
        close
        raise Dalli::NetworkError, message
      end

      def fork_detected?
        @pid && @pid != PIDCache.pid
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
    end
  end
end
