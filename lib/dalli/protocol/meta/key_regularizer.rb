# frozen_string_literal: true

require 'base64'

module Dalli
  module Protocol
    class Meta
      ##
      # The meta protocol requires that keys be ASCII only, so Unicode keys are
      # not supported.  In addition, the use of whitespace in the key is not
      # allowed.
      # memcached supports the use of base64 hashes for keys containing
      # whitespace or non-ASCII characters, provided the 'b' flag is included in the request.
      class KeyRegularizer
        WHITESPACE = /\s/.freeze

        def self.encode(key)
          return [key, false] if key.ascii_only? && !WHITESPACE.match(key)

          [Base64.strict_encode64(key), true]
        end

        def self.decode(encoded_key, base64_encoded)
          return encoded_key unless base64_encoded

          Base64.strict_decode64(encoded_key).force_encoding(Encoding::UTF_8)
        end
      end
    end
  end
end
