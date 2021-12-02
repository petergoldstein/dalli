# frozen_string_literal: true

module Dalli
  module Protocol
    class Binary
      ##
      # Class that encapsulates logic for processing binary protocol responses
      # from memcached.  Includes logic for pulling data from an IO source
      # and parsing into local values.  Handles errors on unexpected values.
      ##
      class ResponseProcessor
        RESP_HEADER = '@2nCCnNNQ'
        RESP_HEADER_SIZE = 24

        # Response codes taken from:
        # https://github.com/memcached/memcached/wiki/BinaryProtocolRevamped#response-status
        RESPONSE_CODES = {
          0 => 'No error',
          1 => 'Key not found',
          2 => 'Key exists',
          3 => 'Value too large',
          4 => 'Invalid arguments',
          5 => 'Item not stored',
          6 => 'Incr/decr on a non-numeric value',
          7 => 'The vbucket belongs to another server',
          8 => 'Authentication error',
          9 => 'Authentication continue',
          0x20 => 'Authentication required',
          0x81 => 'Unknown command',
          0x82 => 'Out of memory',
          0x83 => 'Not supported',
          0x84 => 'Internal error',
          0x85 => 'Busy',
          0x86 => 'Temporary failure'
        }.freeze

        def initialize(io_source, value_marshaller)
          @io_source = io_source
          @value_marshaller = value_marshaller
        end

        def read(num_bytes)
          @io_source.read(num_bytes)
        end

        def read_response
          status, extra_len, key_len, body_len, cas = unpack_header(read_header)
          body = read(body_len) if body_len.positive?
          [status, extra_len, body, cas, key_len]
        end

        def unpack_header(header)
          (key_len, extra_len, _, status, body_len, _, cas) = header.unpack(RESP_HEADER)
          [status, extra_len, key_len, body_len, cas]
        end

        def unpack_response_body(extra_len, key_len, body, unpack)
          bitflags = extra_len.positive? ? body.byteslice(0, extra_len).unpack1('N') : 0x0
          key = body.byteslice(extra_len, key_len) if key_len.positive?
          value = body.byteslice(extra_len + key_len, body.bytesize - (extra_len + key_len))
          value = unpack ? @value_marshaller.retrieve(value, bitflags) : value
          [key, value]
        end

        def read_header
          read(RESP_HEADER_SIZE) || raise(Dalli::NetworkError, 'No response')
        end

        def not_found?(status)
          status == 1
        end

        NOT_STORED_STATUSES = [2, 5].freeze
        def not_stored?(status)
          NOT_STORED_STATUSES.include?(status)
        end

        def raise_on_not_ok_status!(status)
          return if status.zero?

          raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
        end

        def generic_response(unpack: false, cache_nils: false)
          status, extra_len, body, _, key_len = read_response

          return cache_nils ? ::Dalli::NOT_FOUND : nil if not_found?(status)
          return false if not_stored?(status) # Not stored, normal status for add operation

          raise_on_not_ok_status!(status)
          return true unless body

          unpack_response_body(extra_len, key_len, body, unpack).last
        end

        def data_cas_response
          status, extra_len, body, cas, key_len = read_response
          return [nil, cas] if not_found?(status)
          return [nil, false] if not_stored?(status)

          raise_on_not_ok_status!(status)
          return [nil, cas] unless body

          [unpack_response_body(extra_len, key_len, body, true).last, cas]
        end

        def cas_response
          data_cas_response.last
        end

        def multi_with_keys_response
          hash = {}
          loop do
            status, extra_len, body, _, key_len = read_response
            # This is the response to the terminating noop / end of stat
            return hash if status.zero? && key_len.zero?

            # Ignore any responses with non-zero status codes,
            # such as errors from set operations.  That allows
            # this code to be used at the end of a multi
            # block to clear any error responses from inside the multi.
            next unless status.zero?

            key, value = unpack_response_body(extra_len, key_len, body, true)
            hash[key] = value
          end
        end

        def decr_incr_response
          body = generic_response
          body ? body.unpack1('Q>') : body
        end

        def validate_auth_format(extra_len, count)
          return if extra_len.zero?

          raise Dalli::NetworkError, "Unexpected message format: #{extra_len} #{count}"
        end

        def auth_response(buf = read_header)
          (_, extra_len, _, status, body_len,) = buf.unpack(RESP_HEADER)
          validate_auth_format(extra_len, body_len)
          content = read(body_len) if body_len.positive?
          [status, content]
        end

        def contains_header?(buf)
          return false unless buf

          buf.bytesize >= RESP_HEADER_SIZE
        end

        def response_header_from_buffer(buf)
          header = buf.slice(0, RESP_HEADER_SIZE)
          status, extra_len, key_len, body_len, cas = unpack_header(header)
          [status, extra_len, key_len, body_len, cas]
        end

        ##
        # This method returns an array of values used in a pipelined
        # getk process.  The first value is the number of bytes by
        # which to advance the pointer in the buffer.  If the
        # complete response is found in the buffer, this will
        # be the response size.  Otherwise it is zero.
        #
        # The remaining four values in the array are the status, key,
        # value, and cas returned from the response.
        ##
        def getk_response_from_buffer(buf)
          # There's no header in the buffer, so don't advance
          return [0, 0, nil, nil, nil] unless contains_header?(buf)

          status, extra_len, key_len, body_len, cas = response_header_from_buffer(buf)

          # The response has no body - so we need to advance the
          # buffer.  This is either the response to the terminating
          # noop or, if the status is not zero, an intermediate
          # error response that needs to be discarded.
          return [RESP_HEADER_SIZE, status, nil, nil, cas] if body_len.zero?

          # The header is in the buffer, but the body is not
          resp_size = RESP_HEADER_SIZE + body_len
          return [0, status, nil, nil, nil] unless buf.bytesize >= resp_size

          # The full response is in our buffer, so parse it and return
          # the values
          body = buf.slice(RESP_HEADER_SIZE, body_len)
          key, value = unpack_response_body(extra_len, key_len, body, true)
          [resp_size, status, key, value, cas]
        end
      end
    end
  end
end
