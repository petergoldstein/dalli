# frozen_string_literal: true

module Dalli
  module Flags
    # https://www.hjp.at/zettel/m/memcached_flags.rxml
    # Looks like most clients use bit 0 to indicate native language serialization
    SERIALIZED = 0x1

    # https://www.hjp.at/zettel/m/memcached_flags.rxml
    # Looks like most clients use bit 1 to indicate gzip compression.
    COMPRESSED = 0x2

    UTF8 = 0x4
  end
end
