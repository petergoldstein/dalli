# frozen_string_literal: true

require 'socket'
require 'timeout'

module Dalli
  module Protocol
    # Compact the buffer when the consumed portion exceeds this
    # threshold and represents more than half the buffer
    COMPACT_THRESHOLD = 4096

    ##
    # Manages the buffer for responses from memcached.
    # Uses an offset-based approach to avoid string allocations
    # when advancing through parsed responses.
    ##
    class ResponseBuffer
      def initialize(io_source, response_processor)
        @io_source = io_source
        @response_processor = response_processor
        @buffer = nil
        @offset = 0
      end

      def read
        remaining_bytes = @buffer.bytesize - @offset
        if remaining_bytes.zero?
          @offset = 0
          @buffer = @io_source.read_available(@buffer)
        else
          if @offset > COMPACT_THRESHOLD && @offset > (@buffer.bytesize / 2)
            @buffer.bytesplice(0, @offset, '')
            @offset = 0
          end
          @buffer << @io_source.read_available
        end
      end

      # Attempts to process a single response from the buffer,
      # advancing the offset past the consumed bytes.
      def process_single_getk_response
        bytes, status, cas, key, value = @response_processor.getk_response_from_buffer(@buffer, @offset)
        @offset += bytes
        [status, cas, key, value]
      end

      # Resets the internal buffer to an empty state,
      # so that we're ready to read pipelined responses
      def reset
        @buffer&.clear
        @buffer ||= ''.b
        @offset = 0
      end

      # Ensures the buffer is initialized for reading without discarding
      # existing data. Used by interleaved pipelined get which may have
      # already buffered partial responses during the send phase.
      def ensure_ready
        return if in_progress?

        @buffer = ''.b
        @offset = 0
      end

      # Clear the internal response buffer
      def clear
        @buffer&.clear
        @buffer = nil
        @offset = 0
      end

      def in_progress?
        !@buffer.nil?
      end
    end
  end
end
