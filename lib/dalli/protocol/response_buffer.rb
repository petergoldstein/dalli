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
      end

      def read
        @buffer << @io_source.read_nonblock
      end

      # Attempts to process a single response from the buffer.  Starts
      # by advancing the buffer to the specified start position
      def process_single_getk_response
        bytes, status, cas, key, value = @response_processor.getk_response_from_buffer(@buffer)
        advance(bytes)
        [status, cas, key, value]
      end

      # Advances the internal response buffer by bytes_to_advance
      # bytes.  The
      def advance(bytes_to_advance)
        return unless bytes_to_advance.positive?

        @buffer = @buffer.byteslice(bytes_to_advance..-1)
      end

      # Resets the internal buffer to an empty state,
      # so that we're ready to read pipelined responses
      def reset
        @buffer = ''.b
      end

      # Clear the internal response buffer
      def clear
        @buffer = nil
      end

      def in_progress?
        !@buffer.nil?
      end
    end
  end
end
