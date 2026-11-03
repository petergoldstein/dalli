# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      ##
      # The meta protocol requires that keys be ASCII only, so Unicode keys are
      # not supported.  In addition, the use of whitespace in the key is not
      # allowed.
      # memcached supports the use of base64 hashes for keys containing
      # whitespace or non-ASCII characters, provided the 'b' flag is included in the request.
      module KeyRegularizer
        module_function

        # protocol.txt requires that a key "must not include control
        # characters or whitespace" -- \p{Cntrl} is C0 (0x00-0x1F) plus DEL
        # (0x7F). \s alone misses NUL and the rest of that range: a key
        # containing one of those bytes but no whitespace is ASCII-only, so
        # it would otherwise be written to the wire unencoded. Not a
        # protocol-injection risk (the text protocol splits on CRLF, not
        # other control bytes), but a downstream consumer that treats the key
        # specially at one of those bytes (a C string terminating at NUL, a
        # terminal or log line interpreting an escape byte) could silently
        # act on a different key than Dalli believes it sent.
        #
        # Written as \p{Cntrl} rather than the POSIX [:cntrl:] bracket class:
        # \s and [:cntrl:] overlap (tab, newline, CR are in both), and Ruby
        # warns "character class has duplicated range" when they're combined
        # in one -- fatal here, since this suite's -w run treats warnings as
        # errors (see test_strict_warnings.rb). \p{Cntrl} matches the same
        # bytes without the overlap warning.
        #
        # The ascii_only? check runs first, so the regexp only ever sees ASCII
        # keys. Over ASCII, [\p{Cntrl}\s] is exactly 0x00-0x20 plus 0x7F, and
        # the plain byte class below is about 5x faster to match.
        ASCII_CNTRL_OR_SPACE = /[\x00-\x20\x7F]/
        private_constant :ASCII_CNTRL_OR_SPACE

        def required?(key)
          !key.ascii_only? || ASCII_CNTRL_OR_SPACE.match?(key)
        end

        def encode(key)
          [key].pack('m0')
        end

        def decode(encoded_key)
          strict_base64_decoded = encoded_key.unpack1('m0')
          strict_base64_decoded.force_encoding(Encoding::UTF_8)
        end
      end
    end
  end
end
