# frozen_string_literal: true

module Dalli
  module Protocol
    ##
    # Utility class for sanitizing TTL arguments based on Memcached rules.
    # TTLs are either expirations times in seconds (with a maximum value of
    # 30 days) or expiration timestamps.  This class sanitizes TTLs to ensure
    # they meet those restrictions.
    ##
    class TtlSanitizer
      # https://github.com/memcached/memcached/blob/master/doc/protocol.txt#L79
      # > An expiration time, in seconds. Can be up to 30 days. After 30 days, is
      #   treated as a unix timestamp of an exact date.
      MAX_ACCEPTABLE_EXPIRATION_INTERVAL = 30 * 24 * 60 * 60 # 30 days

      # Ensures the TTL passed to Memcached is a valid TTL in the expected format.
      def self.sanitize(ttl)
        ttl_as_i = ttl.to_i
        return ttl_as_i if less_than_max_expiration_interval?(ttl_as_i)

        as_timestamp(ttl_as_i)
      end

      def self.less_than_max_expiration_interval?(ttl_as_i)
        ttl_as_i <= MAX_ACCEPTABLE_EXPIRATION_INTERVAL
      end

      def self.as_timestamp(ttl_as_i)
        now = current_timestamp
        return ttl_as_i if ttl_as_i > now # Already a timestamp

        Dalli.logger.debug "Expiration interval (#{ttl_as_i}) too long for Memcached " \
                           'and too short to be a future timestamp,' \
                           'converting to an expiration timestamp'
        now + ttl_as_i
      end

      # Pulled out into a method so it's easy to stub time
      def self.current_timestamp
        Time.now.to_i
      end
    end
  end
end
