# frozen_string_literal: true

require 'English'
require 'socket'
require 'timeout'

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
        keepalive: true,
        # On JRuby and TruffleRuby, time out reads after socket_timeout (see
        # ReadTimeout). CRuby always does.
        enforce_read_timeout: false
      }.freeze

      attr_accessor :hostname, :port, :socket_type, :options
      attr_reader :sock
      # The buffer replies are read into (see Base#response_buffer). It's
      # cleared with the write buffer whenever the connection closes.
      attr_writer :response_buffer

      # The largest value a reply held during a send may declare: the
      # protocol's max_response_bytes (see HeldReplies). Kept in options, as
      # each instance variable here costs every request a little.
      def max_reply_value_bytes=(bytes)
        @options[:max_reply_value_bytes] = bytes
      end

      def initialize(hostname, port, socket_type, client_options)
        @hostname = hostname
        @port = port
        @socket_type = socket_type
        @options = DEFAULTS.merge(client_options)
        @request_in_progress = false
        @request_sent = false
        @quiet_responses_pending = false
        @sock = nil
        @pid = nil
        @write_buffer = []
        @write_buffer_bytes = 0
        @response_buffer = nil
        # Replies that arrived while a request was being sent, read before the
        # socket while @held (see #send_while_reading)
        @held_replies = nil
        @held = false
        @unanswered_bytes = 0

        @fail_count = 0
        # Where the client's with_deadline keeps its deadline (see
        # check_deadline!), and this request's waits when it cuts them short
        @deadline_key = @options[:deadline_key]
        @deadline = nil
        @request_timeout = nil
        reset_down_info
        extend ReadTimeout if @options[:enforce_read_timeout] && RUBY_ENGINE != 'ruby'
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
        @quiet_responses_pending = false
        @last_used_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError, SocketError => e
        # SocketError = DNS resolution failure; SSL_ERRORS = failed TLS handshake
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

      # Before a request: closes a connection left mid-request, reconnects
      # after a fork, and checks a connection that sat idle (see
      # #close_if_closed_by_peer!). Idle time runs from the start of the last
      # request, so the clock is read once per request; after a request that
      # itself took over a second, the next just makes a check that finds
      # nothing. Pending quiet replies are readable and expected, so the
      # check, and the clock read, are skipped while there are any; in a quiet
      # block that is every write after the first.
      def confirm_ready!
        close if request_in_progress?
        reconnect_on_fork if fork_detected?
        return if @sock.nil? || @quiet_responses_pending

        # Held replies with no request waiting for them were never asked for
        return close if @held

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        idle = now - @last_used_at
        @last_used_at = now
        close_if_closed_by_peer! if idle >= IDLE_CHECK_MS
      end

      # How long, in milliseconds, a connection goes without a request before
      # the next one first checks that the server hasn't closed it. Integer
      # milliseconds keep Float arithmetic off the request path.
      IDLE_CHECK_MS = 1000

      # memcached's idle_timeout, a load balancer or a firewall can close a
      # connection that sat unused. The next write still succeeds, into the
      # kernel's buffer, and only the read fails, by which time the request
      # counts as sent: one that isn't safe to send twice, such as an incr or
      # an add, then raises instead of being retried. With no replies pending,
      # an idle connection has nothing to read, so a readable one was closed
      # by the other end (or holds bytes nothing asked for). Closing it here
      # lets the request go out on a new connection. A connection dropped
      # without the other end being told can't be detected this way.
      def close_if_closed_by_peer!
        return unless @sock.to_io.wait_readable(0)

        Dalli.logger.debug { "#{name} closed the connection while it was idle; reconnecting" }
        close
      rescue IOError, SystemCallError
        close
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
        ensure
          # A non-StandardError (e.g. a second Async::Stop fired into the
          # fiber while it is already inside this cleanup) can escape
          # @sock.close; run the state cleanup unconditionally so the client
          # isn't returned to the pool with a half-closed socket and
          # @request_in_progress == true.
          @sock = nil
          @pid = nil
          @quiet_responses_pending = false
          discard_write_buffer
          discard_held
          @held_replies&.reset_accounting
          @unanswered_bytes = 0
          @response_buffer&.clear
          abort_request!
        end
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

      # True when a quiet request was written on this connection and its
      # replies (memcached only suppresses some of them) haven't been
      # consumed by a noop yet.
      def quiet_responses_pending?
        @quiet_responses_pending
      end

      def mark_quiet_responses_pending!
        @quiet_responses_pending = true
      end

      def clear_quiet_responses_pending!
        @quiet_responses_pending = false
      end

      def request_in_progress?
        @request_in_progress
      end

      def start_request!
        raise '[Dalli] Request already in progress. This may be a bug in Dalli.' if @request_in_progress

        @request_in_progress = true
        @request_sent = false
        limit_to_deadline if @deadline
      end

      # Called before each request, ahead of any reconnect. Looks up the
      # deadline of the Client#with_deadline block it's made in, and raises
      # Dalli::DeadlineExceededError if that has passed, so a request that
      # can't run leaves the connection as it is.
      def check_deadline!
        return unless @deadline_key

        @deadline = Fiber[@deadline_key]
        @deadline&.clamp(Float::INFINITY)
      end

      # Bounds a connect by the deadline, when it leaves less than the connect
      # timeout: the socket, a TLS handshake and the version check that
      # follows. Nothing has been sent on the connection yet, so a timeout
      # here closes it and raises Dalli::DeadlineExceededError.
      def within_connect_deadline(&)
        deadline = @deadline_key && Fiber[@deadline_key]
        return yield unless deadline

        timeout = Dalli::Socket.connect_timeout_for(options) || Float::INFINITY
        limit = deadline.clamp(timeout)
        return yield if limit == timeout

        @request_timeout = limit
        Timeout.timeout(limit, &)
      rescue *TIMEOUT_ERRORS => e
        raise unless @request_timeout

        deadline_exceeded!(e)
      ensure
        @request_timeout = nil
      end

      def finish_request!
        raise '[Dalli] No request in progress. This may be a bug in Dalli.' unless @request_in_progress

        @request_in_progress = false
        @request_sent = false
        restore_timeout if @request_timeout
        # A completed request is what proves the server healthy again, so the
        # failure count resets here rather than on reconnect: a server that
        # accepts connections but never answers would otherwise reset it on
        # every retry and never reach socket_max_failures.
        @fail_count = 0
        # The server has read everything sent so far: it answered the last of it
        @unanswered_bytes = 0
        @held_replies.reset_accounting if @held_replies&.counting?
      end

      # Ends a request whose reply isn't read with it: a quiet write, or one of
      # set_multi's or delete_multi's writes. The server hasn't answered, so the
      # failure count stays; the noop that reads the replies resets it.
      def finish_unanswered_request!
        raise '[Dalli] No request in progress. This may be a bug in Dalli.' unless @request_in_progress

        @request_in_progress = false
        @request_sent = false
        restore_timeout if @request_timeout
      end

      def abort_request!
        @request_in_progress = false
        @request_sent = false
        restore_timeout if @request_timeout
      end

      # True once any of the request in progress has been handed to the
      # socket. Writes made outside a request (the version check on connect,
      # draining an earlier quiet block's replies) don't count.
      def request_sent?
        @request_sent
      end

      # The longest reply line Dalli reads, in bytes, CRLF included. A meta
      # reply header is at most about 500 bytes: "VA <size>" plus its flags,
      # the largest being a 250-byte key base64-encoded to 336 bytes, a
      # 20-digit CAS, a 32-byte opaque and a few numeric fields. The longest
      # stats line (stats settings) carries a file path such as ext_path, up
      # to PATH_MAX (4096). 8 KiB leaves room for both, while a server that
      # never sends CRLF can't grow the read buffer without bound.
      MAX_LINE_BYTES = 8 * 1024

      # TruffleRuby's gets with a limit doesn't find a two-byte separator whose
      # bytes arrive in separate reads: it waits for more, or returns the line
      # without them. Every reply line ends in CRLF, checked after the read,
      # so reading to the LF finds the same lines.
      LINE_SEPARATOR = RUBY_ENGINE == 'truffleruby' ? "\n" : "\r\n"

      def read_line
        return held_line if @held

        flush_write_buffer
        data = timed_tls_operation { @sock.gets(LINE_SEPARATOR, MAX_LINE_BYTES) }
        error_on_request!('EOF in read_line') if data.nil?
        # Without its CRLF the line either ran past MAX_LINE_BYTES or was cut
        # short by EOF; either way the connection is out of step
        line_too_long! unless data.end_with?("\r\n")
        data
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
        error_on_request!(e)
      end

      # JRuby doesn't support IO#timeout=, so use custom readfull implementation
      # CRuby 3.3+ has IO#timeout= which makes IO#read work with timeouts
      # memcached can't store an item larger than 1 GiB (its -I maximum), so a
      # reply claiming more (or a negative size) is malformed or hostile.
      # IO#read allocates the full count up front, so check before reading.
      MAX_READ_BYTES = (1024 * 1024 * 1024) + 2 # plus the value's trailing "\r\n"

      def check_read_size!(count)
        return if count.between?(0, MAX_READ_BYTES)

        raise Dalli::DalliError, "Reply size #{count} from #{name} is out of range"
      end

      if RUBY_ENGINE == 'jruby'
        def read(count)
          return held_read(count) if @held

          check_read_size!(count)
          flush_write_buffer
          @sock.readfull(count)
        rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
          error_on_request!(e)
        end
      else
        def read(count)
          return held_read(count) if @held

          check_read_size!(count)
          flush_write_buffer
          read_bytes(count)
        rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
          error_on_request!(e)
        end
      end

      # Alias for callers that want to make the exact-length contract explicit
      # at the call site.
      alias read_exact read

      # Requests are buffered here rather than in the socket's own IO buffer
      # (the socket is sync). Ruby flushes an IO's write buffer when any process
      # holding it closes or finalizes the IO, so after a fork a child could
      # send bytes the parent had buffered but not sent yet: a quiet write would
      # run twice, or the parent's replies would shift onto the wrong requests.
      # A forked child discards this buffer instead. Like IO's own buffer, it
      # is sent once it grows past this size, or when a reply is read.
      WRITE_BUFFER_FLUSH_BYTES = 64 * 1024

      # Less than any socket send buffer: 8 KiB is the smallest default
      # (Unix sockets on macOS), and Linux doubles a requested SO_SNDBUF from
      # a minimum of 2,304 bytes
      BLOCKING_WRITE_BYTES = 4 * 1024

      # jruby-openssl won't read while it has encrypted bytes it couldn't send,
      # and they can't go until the server reads, which it won't while its
      # replies go unread. On JRuby a TLS request is sent as before.
      HALF_DUPLEX_TLS = RUBY_ENGINE == 'jruby'

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

      def flushed_write(bytes)
        @write_buffer << bytes
        flush_write_buffer
        bytes.bytesize
      rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, IOError => e
        error_on_request!(e)
      end

      # Non-blocking read.  Here to support the operation
      # of the get_multi operation. Held replies come first.
      def read_available(...)
        return take_held(@held_replies.bytesize) if @held

        flush_write_buffer
        @sock.read_available(...)
      end

      # Whether replies that arrived during a send are waiting to be read.
      # IO.select can't see them, so a caller waiting for replies checks first.
      def held_replies?
        @held
      end

      def max_allowed_failures
        @max_allowed_failures ||= @options[:socket_max_failures] || 2
      end

      def error_on_request!(err_or_string)
        deadline_exceeded!(err_or_string) if @request_timeout && timeout_error?(err_or_string)
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
        # Read before close, which ends the request
        request_sent = @request_sent
        close
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
        raise Dalli::RetryableNetworkError.new(message, request_sent: request_sent)
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

      # Ruby 3.3's default OpenSSL can block past IO#timeout= on the TCP
      # socket. Bound the blocking TLS call itself; error_on_request! closes
      # the connection after the Timeout::Error, so a partial reply or write
      # is never reused.
      def timed_tls_operation(&)
        return yield unless @sock.is_a?(Dalli::Socket::SSLSocket)

        Timeout.timeout(@request_timeout || socket_timeout, &)
      end

      # Cuts this request's waits to the time its deadline leaves, when that's
      # less than socket_timeout. CRuby enforces it through IO#timeout=; the
      # TLS and enforce_read_timeout waits read @request_timeout.
      def limit_to_deadline
        timeout = socket_timeout || Float::INFINITY
        limit = @deadline.clamp(timeout)
        return if limit == timeout

        @request_timeout = limit
        io = @sock&.to_io
        io.timeout = limit if io.respond_to?(:timeout=)
      end

      def restore_timeout
        io = @sock&.to_io
        io.timeout = socket_timeout if io.respond_to?(:timeout=)
        @request_timeout = nil
      end

      def timeout_error?(err_or_string)
        TIMEOUT_ERRORS.any? { |klass| err_or_string.is_a?(klass) }
      end

      # A wait cut short by a deadline ended the call. The connection is closed,
      # as the reply may be half read, but the timeout says nothing about the
      # server, so it isn't counted against it and the call isn't retried.
      def deadline_exceeded!(err)
        Dalli.logger.debug { "#{name}: deadline exceeded (#{err.class})" }
        close
        @request_timeout = nil
        raise Dalli::DeadlineExceededError, "Deadline exceeded waiting for #{name}"
      end

      # One write per flush. A TLS socket sends each argument of
      # write(*parts) as its own record and system call, so the parts are
      # joined first.
      #
      # A write blocks while the socket's send buffer is full. memcached stops
      # reading a connection while its replies go unread, so once the requests
      # it hasn't answered are more than the buffers hold, a blocking write
      # and the server wait on each other until socket_timeout. Up to
      # BLOCKING_WRITE_BYTES unanswered, the write fits whatever the server
      # is doing; past that, #send_while_reading takes the replies off the
      # socket while it sends.
      def flush_write_buffer
        return if @write_buffer.empty?

        # Set before writing: a write that fails may still have sent some bytes
        @request_sent = true if @request_in_progress
        data = @write_buffer.size == 1 ? @write_buffer.first : joined_write_buffer
        @unanswered_bytes += data.bytesize
        if @unanswered_bytes <= BLOCKING_WRITE_BYTES
          write_blocking(data)
        else
          send_while_reading(data)
        end
        discard_write_buffer
      end

      # The write every request makes, kept free of a block outside TLS: a
      # block here measurably slowed each request
      def write_blocking(data)
        return @sock.write(data) unless @sock.is_a?(Dalli::Socket::SSLSocket)

        Timeout.timeout(socket_timeout) { @sock.write(data) }
      end

      # Sends without blocking, holding the replies that arrive meanwhile (see
      # HeldReplies). Fails after socket_timeout with nothing sent, as a
      # blocking write does, or when a held reply isn't one the requests sent
      # could get.
      def send_while_reading(data)
        return write_blocking(data) if HALF_DUPLEX_TLS && @sock.is_a?(OpenSSL::SSL::SSLSocket)

        total = data.bytesize
        sent = 0
        deadline = nil
        counted = false
        while sent < total
          rest = sent.zero? ? data : data.byteslice(sent, total - sent)
          result = @sock.write_nonblock(rest, exception: false)
          if result.is_a?(Integer)
            sent += result
            deadline = nil
          else
            # Replies can only be held from here, so the lines are counted now
            counted ||= (@held_replies ||= HeldReplies.new(max_reply_value_bytes)).count_lines(data)
            deadline ||= write_deadline
            wait_to_send(result, deadline)
          end
        end
      end

      # Waits until the socket takes more, holding any replies that arrive.
      # TLS can need the other direction first, and the socket is ready for
      # the direction it doesn't need, so waiting on that too would return at
      # once: a write can need to read (:wait_readable), and a read can need
      # to write (:wait_writable).
      def wait_to_send(wait_for, deadline)
        readable, = wait_until(deadline, [@sock], wait_for == :wait_writable ? [@sock] : nil)
        return if readable.empty?

        wait_until(deadline, nil, [@sock]) if hold_arrived_replies == :wait_writable
      end

      def wait_until(deadline, readers, writers)
        wait = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
        raise Timeout::Error, "IO timeout writing to #{name}" if wait && wait <= 0

        IO.select(readers, writers, nil, wait) or raise Timeout::Error, "IO timeout writing to #{name}"
      end

      def write_deadline
        socket_timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + socket_timeout)
      end

      def max_reply_value_bytes
        @options.fetch(:max_reply_value_bytes, MAX_READ_BYTES - 2)
      end

      # Returns what read_nonblock did when nothing was held
      def hold_arrived_replies
        result = @held_replies.read_from(@sock, @unanswered_bytes)
        @held = true if result.nil?
        result
      rescue HeldReplies::Invalid => e
        error_on_request!("#{name} sent #{e.message}")
      end

      # A held reply line. One that continues on the socket is finished from
      # there. A CR that ends the held bytes may be the first half of its CRLF,
      # which gets wouldn't find across the two.
      def held_line
        length, whole = @held_replies.next_line_length
        line_too_long! if length > MAX_LINE_BYTES
        return take_held(length) if whole

        line = take_held(length)
        line << read(1) while line.end_with?("\r") && line.bytesize <= MAX_LINE_BYTES
        line << read_line unless line.end_with?("\r\n")
        line_too_long! if line.bytesize > MAX_LINE_BYTES
        line
      end

      # count bytes, the held ones first
      def held_read(count)
        check_read_size!(count)
        held = @held_replies.bytesize
        return take_held(count) if held >= count

        value = take_held(held)
        value << read(count - held)
      end

      def take_held(count)
        part = @held_replies.take(count)
        @held = false if @held_replies.empty?
        part
      end

      def discard_held
        @held = false
        @held_replies&.clear
      end

      def line_too_long!
        error_on_request!("Reply line without CRLF in the first #{MAX_LINE_BYTES} bytes")
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

      # Reads exactly `count` bytes. IO#read(count) on a blocking socket blocks
      # until it has `count` bytes, accumulating across TCP chunks internally,
      # and only hands back a shorter (or nil) buffer when the stream hits EOF.
      # So a short read means the peer closed mid-response: raise EOFError and
      # let read's existing `rescue EOFError` route it through
      # error_on_request!, which closes the dirty socket for a retry on a fresh
      # connection (and preserves the $ERROR_INFO context down! relies on).
      def read_bytes(count)
        buffer = timed_tls_operation { @sock.read(count) }
        return buffer if buffer && buffer.bytesize == count

        raise EOFError, "EOF reading #{count} bytes; received #{buffer ? buffer.bytesize : 0}"
      end

      # CRuby enforces socket_timeout on reads through IO#timeout=. TruffleRuby
      # has no IO#timeout=, and JRuby (as of 10.1) defines it but doesn't
      # enforce it; both ignore the SO_RCVTIMEO fallback, so a read from a
      # server that stopped answering blocks forever. With
      # enforce_read_timeout, the first read after a request is sent waits for
      # the socket to be readable, up to socket_timeout. It's opt-in because
      # the wait costs about 8% of single-key throughput on TruffleRuby and
      # 20-29% on JRuby. A server that stops partway through a reply line can
      # still block. So can one that stops partway through a value on
      # TruffleRuby; JRuby reads values without blocking.
      #
      # TLS connections are left as they were: OpenSSL buffers decrypted
      # bytes that wait_readable can't see.
      module ReadTimeout
        def read_line
          flush_write_buffer
          if @awaiting_reply
            @awaiting_reply = false
            # A reply held while the request was sent has already arrived
            wait_readable! unless @held || @sock.is_a?(::OpenSSL::SSL::SSLSocket)
          end
          super
        rescue SystemCallError, *TIMEOUT_ERRORS, *SSL_ERRORS, EOFError => e
          error_on_request!(e)
        end

        private

        def flush_write_buffer
          @awaiting_reply = true unless @write_buffer.empty?
          super
        end

        def wait_readable!
          @sock.wait_readable(@request_timeout || socket_timeout) or
            raise Timeout::Error, "IO timeout reading from #{name}"
        end
      end
    end
  end
end
