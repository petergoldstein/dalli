# frozen_string_literal: true

require 'socket'
require 'timeout'

module Dalli
  module Protocol
    ##
    # Manages the buffer for responses from memcached.
    ##
    class ResponseBuffer
      def initialize(io_source, response_processor)
        @io_source = io_source
        @response_processor = response_processor
        @buffer = nil
        @offset = 0
      end

      def read
        @buffer << @io_source.read_nonblock
      end

      # Attempts to process a single response from the buffer.
      def process_single_getk_response
        bytes, status, cas, key, value = @response_processor.getk_response_from_buffer(@buffer, @offset)
        if bytes.positive?
          @offset += bytes
        else
          # Clear out read values if the buffer doesn't contain a full response
          clear_read_values
        end
        [status, cas, key, value]
      end

      # Clears already read values out of the buffer.
      def clear_read_values
        return unless @offset.positive?

        @buffer = @buffer.byteslice(@offset..-1)
        clear_offset
      end

      # Resets the internal buffer to an empty state,
      # so that we're ready to read pipelined responses
      def reset
        @buffer = ''.b
        clear_offset
      end

      # Clear the internal response buffer
      def clear
        @buffer = nil
        clear_offset
      end

      def in_progress?
        !@buffer.nil?
      end

      def clear_offset
        @offset = 0
      end
    end
  end
end
