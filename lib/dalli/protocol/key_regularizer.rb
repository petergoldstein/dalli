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

        def required?(key)
          !key.ascii_only? || /\s/.match?(key)
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
