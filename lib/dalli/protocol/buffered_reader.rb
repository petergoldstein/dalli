# frozen_string_literal: true

require 'socket'
require 'timeout'

module Dalli
  module Protocol
    ##
    # Manages the buffer for responses from memcached.
    ##
    class BufferedReader
      ENCODING = Encoding::BINARY
      TERMINATOR = "\r\n".b.freeze
      TERMINATOR_SIZE = TERMINATOR.bytesize

      attr_reader :buffer

      def initialize(io)
        @io = io
        @buffer = +''
        @offset = 0
        @chunk_size = 8196
        @timeout = 10000 # ms
      end

      # Reads line from io and the buffer, value does not include the terminator
      def read_line
        fill_buffer(false) if @offset >= @buffer.bytesize
        until terminator_index = @buffer.index(TERMINATOR, @offset)
          fill_buffer(false)
        end

        line = @buffer.byteslice(@offset, terminator_index - @offset)
        @offset = terminator_index + TERMINATOR_SIZE
        line.force_encoding(Encoding::UTF_8)
      end

      def read_exact(size)
        size = size + TERMINATOR_SIZE
        needed = size - (@buffer.bytesize - @offset)
        if needed > 0
          fill_buffer(true, needed)
        end

        str = @buffer.byteslice(@offset, size)
        @offset += size + TERMINATOR_SIZE
        str.force_encoding(Encoding::UTF_8)
      end

      def fill_buffer(force_size, size = @chunk_size)
        remaining = size
        buffer_size = @buffer.bytesize
        start = @offset - buffer_size
        buffer_is_empty = start >= 0
        current_timeout = @timeout

        loop do
          start_time = Time.now
          bytes = if buffer_is_empty
            @io.read_nonblock([remaining, @chunk_size].max, @buffer, exception: false)
          else
            @io.read_nonblock([remaining, @chunk_size].max, exception: false)
          end

          case bytes
          when :wait_readable
            if buffer_is_empty && @buffer.empty?
              @offset -= buffer_size
            end

            unless @io.wait_readable(current_timeout / 1000.0)
              raise "TIMEOUT ERROR"
            end
          when :wait_writable
            raise "How did we get here?"
          when nil
            raise "EOF ERROR"
          else
            if buffer_is_empty
              @offset = start
              buffer_is_empty = false
              @buffer.force_encoding(ENCODING) if @buffer.encoding != ENCODING
            else
              @buffer << bytes.force_encoding(ENCODING)
            end
            remaining -= bytes.bytesize

            return if !force_size || remaining <= 0
          end

          current_timeout = [current_timeout - ((Time.now - start_time) * 1000), 0].max
          if current_timeout <= 0
            raise "TIMEOUT ERROR"
          end
        end
      end
    end
  end
end
