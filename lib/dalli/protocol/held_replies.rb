# frozen_string_literal: true

module Dalli
  module Protocol
    ##
    # Replies that arrived while a request was being sent (see
    # ConnectionManager#send_while_reading), held until the request's reader
    # gets to them. Created only once a send has had to wait, so connections
    # that never send a large request don't carry its state.
    #
    # Held bytes are checked as they arrive, so that what's held is never more
    # than the requests sent could get back: whole reply lines of up to
    # ConnectionManager::MAX_LINE_BYTES, no more replies than request lines
    # sent, and values no larger than max_response_bytes. Anything else raises
    # Invalid as soon as it's read.
    ##
    class HeldReplies
      class Invalid < StandardError; end

      # Read per wakeup: enough to empty a Unix socket's send buffer (208 KiB
      # by default on Linux)
      READ_BYTES = 256 * 1024

      def initialize(max_value_bytes)
        @max_value_bytes = max_value_bytes
        @buffer = ''.b
        @offset = 0
        @chunk = nil
        @line = ''.b
        reset_accounting
      end

      # Whether lines were counted since the server last answered everything
      def counting?
        @counting
      end

      # Each request line can get one reply. Only the lines of a send that had
      # to wait are counted: the socket took the others at once, as it does a
      # blocking write's, and each of their bytes is allowed one.
      def count_lines(data)
        @counting = true
        @counted_bytes += data.bytesize
        @lines += data.count("\n")
        true
      end

      # The server has answered everything sent so far
      def reset_accounting
        @counting = false
        @counted_bytes = 0
        @lines = 0
        @replies = 0
        @value_left = 0
        @line.clear
      end

      # Moves the replies that have arrived on sock into the buffer, reading
      # into it directly when it's empty, then checks them. Returns nil once
      # bytes are held, or what read_nonblock returned when none were.
      # unanswered_bytes is everything sent since the server last answered.
      def read_from(sock, unanswered_bytes)
        if empty?
          @offset = 0
          from = 0
          result = sock.read_nonblock(READ_BYTES, @buffer, exception: false)
        else
          compact
          from = @buffer.bytesize
          result = sock.read_nonblock(READ_BYTES, @chunk ||= ''.b, exception: false)
          @buffer << result if result.is_a?(String)
        end
        raise EOFError, 'EOF while sending' if result.nil?
        # Nothing held: TLS read a handshake record, or nothing had arrived
        return result unless result.is_a?(String)

        check(from, unanswered_bytes)
        nil
      end

      def empty?
        @offset == @buffer.bytesize
      end

      def bytesize
        @buffer.bytesize - @offset
      end

      # The length of the next line, CRLF included, and whether its CRLF is
      # held. Without it, the line runs to the end of what's held.
      def next_line_length
        eol = @buffer.byteindex("\r\n", @offset)
        eol ? [eol + 2 - @offset, true] : [bytesize, false]
      end

      # The next count bytes. Bytes that reach the end are copied: a byteslice
      # there would share the buffer's memory and keep it all allocated.
      def take(count)
        if @offset + count < @buffer.bytesize
          part = @buffer.byteslice(@offset, count)
          @offset += count
        else
          part = String.new(capacity: count, encoding: Encoding::BINARY)
          part.bytesplice(0, 0, @buffer, @offset, count)
          clear
        end
        part
      end

      def clear
        @buffer.clear
        @offset = 0
      end

      private

      def compact
        return unless @offset > COMPACT_THRESHOLD && @offset > (@buffer.bytesize / 2)

        @buffer.bytesplice(0, @offset, '')
        @offset = 0
      end

      # Checks the held bytes from pos, keeping its place in a line or value
      # that continues in the next read
      def check(pos, unanswered_bytes)
        size = @buffer.bytesize
        while pos < size
          if @value_left.positive?
            step = [@value_left, size - pos].min
            @value_left -= step
            pos += step
            next
          end

          eol = @buffer.byteindex("\n", pos)
          @line << @buffer.byteslice(pos, (eol ? eol + 1 : size) - pos)
          line_too_long! if @line.bytesize > ConnectionManager::MAX_LINE_BYTES
          return unless eol

          pos = eol + 1
          check_reply(@line, unanswered_bytes)
          @line.clear
        end
      end

      def check_reply(line, unanswered_bytes)
        line_too_long! unless line.end_with?("\r\n")

        @replies += 1
        if @replies > unanswered_bytes - @counted_bytes + @lines
          raise Invalid, 'more replies than requests while they were being sent'
        end
        return unless line.start_with?('VA ')

        size = line[/\AVA (\d+)[ \r]/, 1]&.to_i
        unless size && size <= @max_value_bytes
          raise Invalid, 'a value larger than max_response_bytes while a request was being sent'
        end

        @value_left = size + 2
      end

      def line_too_long!
        raise Invalid, "a reply line without CRLF in the first #{ConnectionManager::MAX_LINE_BYTES} bytes"
      end
    end
  end
end
