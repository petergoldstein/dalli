# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      ##
      # Class that encapsulates logic for processing meta protocol responses
      # from memcached.  Includes logic for pulling data from an IO source
      # and parsing into local values.  Handles errors on unexpected values.
      ##
      class ResponseProcessor
        EN = 'EN'
        END_TOKEN = 'END'
        EX = 'EX'
        HD = 'HD'
        MN = 'MN'
        NF = 'NF'
        NS = 'NS'
        OK = 'OK'
        RESET = 'RESET'
        STAT = 'STAT'
        VA = 'VA'
        VERSION = 'VERSION'
        SERVER_ERROR = 'SERVER_ERROR'

        def initialize(io_source, value_marshaller)
          @io_source = io_source
          @value_marshaller = value_marshaller
        end

        def meta_get_with_value(cache_nils: false)
          tokens = error_on_unexpected!([VA, EN, HD])
          return cache_nils ? ::Dalli::NOT_FOUND : nil if tokens.first == EN
          return true unless tokens.first == VA

          @value_marshaller.retrieve(read_data(tokens[1].to_i), bitflags_from_tokens(tokens))
        end

        def meta_get_with_value_and_cas
          tokens = error_on_unexpected!([VA, EN, HD])
          return [nil, 0] if tokens.first == EN

          cas = cas_from_tokens(tokens)
          return [nil, cas] unless tokens.first == VA

          [@value_marshaller.retrieve(read_data(tokens[1].to_i), bitflags_from_tokens(tokens)), cas]
        end

        def meta_get_without_value
          tokens = error_on_unexpected!([EN, HD])
          tokens.first == EN ? nil : true
        end

        # Returns a hash with all requested metadata:
        # - :value - the cached value (or nil if miss)
        # - :cas - the CAS value (if return_cas was requested)
        # - :won_recache - true if client won the right to recache (W flag)
        # - :stale - true if the item is stale (X flag)
        # - :lost_recache - true if another client is already recaching (Z flag)
        # - :hit_before - true/false if item was previously accessed (h flag, if requested)
        # - :last_access - seconds since last access (l flag, if requested)
        #
        # Used by meta_get for comprehensive metadata retrieval.
        # Supports thundering herd protection (N/R flags) and metadata flags (h/l/u).
        def meta_get_with_metadata(cache_nils: false, return_hit_status: false, return_last_access: false)
          tokens = error_on_unexpected!([VA, EN, HD])
          result = build_metadata_result(tokens)
          result[:hit_before] = hit_status_from_tokens(tokens) if return_hit_status
          result[:last_access] = last_access_from_tokens(tokens) if return_last_access
          result[:value] = parse_value_from_tokens(tokens, cache_nils)
          result
        end

        def build_metadata_result(tokens)
          {
            value: nil, cas: cas_from_tokens(tokens),
            won_recache: tokens.include?('W'), stale: tokens.include?('X'),
            lost_recache: tokens.include?('Z')
          }
        end

        def parse_value_from_tokens(tokens, cache_nils)
          return cache_nils ? ::Dalli::NOT_FOUND : nil if tokens.first == EN
          return unless tokens.first == VA

          @value_marshaller.retrieve(read_data(tokens[1].to_i), bitflags_from_tokens(tokens))
        end

        def meta_set_with_cas
          tokens = error_on_unexpected!([HD, NS, NF, EX])
          return false unless tokens.first == HD

          cas_from_tokens(tokens)
        end

        def meta_set_append_prepend
          tokens = error_on_unexpected!([HD, NS, NF, EX])
          return false unless tokens.first == HD

          true
        end

        def meta_delete
          tokens = error_on_unexpected!([HD, NF, EX])
          tokens.first == HD
        end

        def decr_incr
          tokens = error_on_unexpected!([VA, NF, NS, EX])
          return false if [NS, EX].include?(tokens.first)
          return nil if tokens.first == NF

          read_line.to_i
        end

        def stats
          tokens = error_on_unexpected!([END_TOKEN, STAT])
          values = {}
          while tokens.first != END_TOKEN
            values[tokens[1]] = tokens[2]
            tokens = next_line_to_tokens
          end
          values
        end

        def flush
          error_on_unexpected!([OK])

          true
        end

        def reset
          error_on_unexpected!([RESET])

          true
        end

        def version
          tokens = error_on_unexpected!([VERSION])
          tokens.last
        end

        def consume_all_responses_until_mn
          tokens = next_line_to_tokens

          tokens = next_line_to_tokens while tokens.first != MN
          true
        end

        def full_response_from_buffer(tokens, body, resp_size)
          value = @value_marshaller.retrieve(body, bitflags_from_tokens(tokens))
          [resp_size, tokens.first == VA, cas_from_tokens(tokens), key_from_tokens(tokens), value]
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
        def getk_response_from_buffer(buf, offset = 0)
          # Find the header terminator starting from offset
          term_idx = buf.index(TERMINATOR, offset)
          return [0, nil, nil, nil, nil] unless term_idx

          header = buf.byteslice(offset, term_idx - offset)
          tokens = header.split
          header_len = header.bytesize + TERMINATOR.length
          body_len = body_len_from_tokens(tokens)

          # We have a complete response that has no body.
          # This is either the response to the terminating
          # noop or, if the status is not MN, an intermediate
          # error response that needs to be discarded.
          return [header_len, true, nil, nil, nil] if body_len.zero?

          resp_size = header_len + body_len + TERMINATOR.length
          # The header is in the buffer, but the body is not.  As we don't have
          # a complete response, don't advance the buffer
          return [0, nil, nil, nil, nil] unless buf.bytesize >= offset + resp_size

          # The full response is in our buffer, so parse it and return
          # the values
          body = buf.byteslice(offset + header_len, body_len)
          full_response_from_buffer(tokens, body, resp_size)
        end

        def error_on_unexpected!(expected_codes)
          tokens = next_line_to_tokens

          return tokens if expected_codes.include?(tokens.first)

          raise Dalli::ServerError, tokens.join(' ').to_s if tokens.first == SERVER_ERROR

          raise Dalli::DalliError, "Response error: #{tokens.first}"
        end

        def bitflags_from_tokens(tokens)
          value_from_tokens(tokens, 'f')&.to_i
        end

        def cas_from_tokens(tokens)
          value_from_tokens(tokens, 'c')&.to_i
        end

        def key_from_tokens(tokens)
          encoded_key = value_from_tokens(tokens, 'k')
          base64_encoded = tokens.any?('b')
          KeyRegularizer.decode(encoded_key, base64_encoded)
        end

        # Returns true if item was previously hit, false if first access, nil if not requested
        # The h flag returns h0 (first access) or h1 (previously accessed)
        def hit_status_from_tokens(tokens)
          hit_token = tokens.find { |t| t.start_with?('h') && t.length == 2 }
          return nil unless hit_token

          hit_token[1] == '1'
        end

        # Returns seconds since last access, or nil if not requested
        # The l flag returns l<seconds>
        def last_access_from_tokens(tokens)
          value_from_tokens(tokens, 'l')&.to_i
        end

        def body_len_from_tokens(tokens)
          value_from_tokens(tokens, 's')&.to_i
        end

        def value_from_tokens(tokens, flag)
          bitflags_token = tokens.find { |t| t.start_with?(flag) }
          return 0 unless bitflags_token

          bitflags_token[1..]
        end

        def read_line
          @io_source.read_line&.chomp!(TERMINATOR)
        end

        def next_line_to_tokens
          line = read_line
          line&.split || []
        end

        def read_data(data_size)
          @io_source.read(data_size + TERMINATOR.bytesize)&.chomp!(TERMINATOR)
        end
      end
    end
  end
end
