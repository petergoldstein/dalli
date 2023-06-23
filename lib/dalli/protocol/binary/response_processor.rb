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
          resp_header = ResponseHeader.new(read_header)
          body = read(resp_header.body_len) if resp_header.body_len.positive?
          [resp_header, body]
        end

        def unpack_response_body(resp_header, body, parse_as_stored_value)
          extra_len = resp_header.extra_len
          key_len = resp_header.key_len
          bitflags = extra_len.positive? ? body.unpack1('N') : 0x0
          key = body.byteslice(extra_len, key_len).force_encoding(Encoding::UTF_8) if key_len.positive?
          value = body.byteslice((extra_len + key_len)..-1)
          value = @value_marshaller.retrieve(value, bitflags) if parse_as_stored_value
          [key, value]
        end

        def read_header
          read(ResponseHeader::SIZE) || raise(Dalli::NetworkError, 'No response')
        end

        def raise_on_not_ok!(resp_header)
          return if resp_header.ok?

          raise Dalli::DalliError, "Response error #{resp_header.status}: #{RESPONSE_CODES[resp_header.status]}"
        end

        def get(cache_nils: false)
          resp_header, body = read_response

          return false if resp_header.not_stored? # Not stored, normal status for add operation
          return cache_nils ? ::Dalli::NOT_FOUND : nil if resp_header.not_found?

          raise_on_not_ok!(resp_header)
          return true unless body

          unpack_response_body(resp_header, body, true).last
        end

        ##
        # Response for a storage operation.  Returns the cas on success.  False
        # if the value wasn't stored.  And raises an error on all other error
        # codes from memcached.
        ##
        def storage_response
          resp_header, = read_response
          return nil if resp_header.not_found?
          return false if resp_header.not_stored? # Not stored, normal status for add operation

          raise_on_not_ok!(resp_header)
          resp_header.cas
        end

        def delete
          resp_header, = read_response
          return false if resp_header.not_found? || resp_header.not_stored?

          raise_on_not_ok!(resp_header)
          true
        end

        def data_cas_response
          resp_header, body = read_response
          return [nil, resp_header.cas] if resp_header.not_found?
          return [nil, false] if resp_header.not_stored?

          raise_on_not_ok!(resp_header)
          return [nil, resp_header.cas] unless body

          [unpack_response_body(resp_header, body, true).last, resp_header.cas]
        end

        # Returns the new value for the key, if found and updated
        def decr_incr
          body = generic_response
          body ? body.unpack1('Q>') : body
        end

        def stats
          hash = {}
          loop do
            resp_header, body = read_response
            # This is the response to the terminating noop / end of stat
            return hash if resp_header.ok? && resp_header.key_len.zero?

            # Ignore any responses with non-zero status codes,
            # such as errors from set operations.  That allows
            # this code to be used at the end of a multi
            # block to clear any error responses from inside the multi.
            next unless resp_header.ok?

            key, value = unpack_response_body(resp_header, body, true)
            hash[key] = value
          end
        end

        def flush
          no_body_response
        end

        def reset
          generic_response
        end

        def version
          generic_response
        end

        def consume_all_responses_until_noop
          loop do
            resp_header, = read_response
            # This is the response to the terminating noop / end of stat
            return true if resp_header.ok? && resp_header.key_len.zero?
          end
        end

        def generic_response
          resp_header, body = read_response

          return false if resp_header.not_stored? # Not stored, normal status for add operation
          return nil if resp_header.not_found?

          raise_on_not_ok!(resp_header)
          return true unless body

          unpack_response_body(resp_header, body, false).last
        end

        def no_body_response
          resp_header, = read_response
          return false if resp_header.not_stored? # Not stored, possible status for append/prepend/delete

          raise_on_not_ok!(resp_header)
          true
        end

        def validate_auth_format(extra_len, count)
          return if extra_len.zero?

          raise Dalli::NetworkError, "Unexpected message format: #{extra_len} #{count}"
        end

        def auth_response(buf = read_header)
          resp_header = ResponseHeader.new(buf)
          body_len = resp_header.body_len
          validate_auth_format(resp_header.extra_len, body_len)
          content = read(body_len) if body_len.positive?
          [resp_header.status, content]
        end

        def contains_header?(buf)
          return false unless buf

          buf.bytesize >= ResponseHeader::SIZE
        end

        def response_header_from_buffer(buf)
          ResponseHeader.new(buf)
        end

        ##
        # This method returns an array of values used in a pipelined
        # getk process.  The first value is the number of bytes by
        # which to advance the pointer in the buffer.  If the
        # complete response is found in the buffer, this will
        # be the response size.  Otherwise it is zero.
        #
        # The remaining three values in the array are the ResponseHeader,
        # key, and value.
        ##
        def getk_response_from_buffer(buf)
          # There's no header in the buffer, so don't advance
          return [0, nil, nil, nil, nil] unless contains_header?(buf)

          resp_header = response_header_from_buffer(buf)
          body_len = resp_header.body_len

          # We have a complete response that has no body.
          # This is either the response to the terminating
          # noop or, if the status is not zero, an intermediate
          # error response that needs to be discarded.
          return [ResponseHeader::SIZE, resp_header.ok?, resp_header.cas, nil, nil] if body_len.zero?

          resp_size = ResponseHeader::SIZE + body_len
          # The header is in the buffer, but the body is not.  As we don't have
          # a complete response, don't advance the buffer
          return [0, nil, nil, nil, nil] unless buf.bytesize >= resp_size

          # The full response is in our buffer, so parse it and return
          # the values
          body = buf.byteslice(ResponseHeader::SIZE, body_len)
          key, value = unpack_response_body(resp_header, body, true)
          [resp_size, resp_header.ok?, resp_header.cas, key, value]
        end
      end
    end
  end
end
