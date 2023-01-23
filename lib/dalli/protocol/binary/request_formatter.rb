# frozen_string_literal: true

module Dalli
  module Protocol
    class Binary
      ##
      # Class that encapsulates logic for formatting binary protocol requests
      # to memcached.
      ##
      class RequestFormatter
        REQUEST = 0x80

        OPCODES = {
          get: 0x00,
          set: 0x01,
          add: 0x02,
          replace: 0x03,
          delete: 0x04,
          incr: 0x05,
          decr: 0x06,
          flush: 0x08,
          noop: 0x0A,
          version: 0x0B,
          getkq: 0x0D,
          append: 0x0E,
          prepend: 0x0F,
          stat: 0x10,
          setq: 0x11,
          addq: 0x12,
          replaceq: 0x13,
          deleteq: 0x14,
          incrq: 0x15,
          decrq: 0x16,
          flushq: 0x18,
          appendq: 0x19,
          prependq: 0x1A,
          touch: 0x1C,
          gat: 0x1D,
          auth_negotiation: 0x20,
          auth_request: 0x21,
          auth_continue: 0x22
        }.freeze

        REQ_HEADER_FORMAT = 'CCnCCnNNQ'

        KEY_ONLY = 'a*'
        TTL_AND_KEY = 'Na*'
        KEY_AND_VALUE = 'a*a*'
        INCR_DECR = 'NNNNNa*'
        TTL_ONLY = 'N'
        NO_BODY = ''

        BODY_FORMATS = {
          get: KEY_ONLY,
          getkq: KEY_ONLY,
          delete: KEY_ONLY,
          deleteq: KEY_ONLY,
          stat: KEY_ONLY,

          append: KEY_AND_VALUE,
          prepend: KEY_AND_VALUE,
          appendq: KEY_AND_VALUE,
          prependq: KEY_AND_VALUE,
          auth_request: KEY_AND_VALUE,
          auth_continue: KEY_AND_VALUE,

          set: 'NNa*a*',
          setq: 'NNa*a*',
          add: 'NNa*a*',
          addq: 'NNa*a*',
          replace: 'NNa*a*',
          replaceq: 'NNa*a*',

          incr: INCR_DECR,
          decr: INCR_DECR,
          incrq: INCR_DECR,
          decrq: INCR_DECR,

          flush: TTL_ONLY,
          flushq: TTL_ONLY,

          noop: NO_BODY,
          auth_negotiation: NO_BODY,
          version: NO_BODY,

          touch: TTL_AND_KEY,
          gat: TTL_AND_KEY
        }.freeze
        FORMAT = BODY_FORMATS.transform_values { |v| REQ_HEADER_FORMAT + v }

        # rubocop:disable Metrics/ParameterLists
        def self.standard_request(opkey:, key: nil, value: nil, opaque: 0, cas: 0, bitflags: nil, ttl: nil)
          extra_len = (bitflags.nil? ? 0 : 4) + (ttl.nil? ? 0 : 4)
          key_len = key.nil? ? 0 : key.bytesize
          value_len = value.nil? ? 0 : value.bytesize
          header = [REQUEST, OPCODES[opkey], key_len, extra_len, 0, 0, extra_len + key_len + value_len, opaque, cas]
          body = [bitflags, ttl, key, value].compact
          (header + body).pack(FORMAT[opkey])
        end
        # rubocop:enable Metrics/ParameterLists

        def self.decr_incr_request(opkey:, key: nil, count: nil, initial: nil, expiry: nil)
          extra_len = 20
          (h, l) = as_8byte_uint(count)
          (dh, dl) = as_8byte_uint(initial)
          header = [REQUEST, OPCODES[opkey], key.bytesize, extra_len, 0, 0, key.bytesize + extra_len, 0, 0]
          body = [h, l, dh, dl, expiry, key]
          (header + body).pack(FORMAT[opkey])
        end

        def self.as_8byte_uint(val)
          [val >> 32, val & 0xFFFFFFFF]
        end
      end
    end
  end
end
