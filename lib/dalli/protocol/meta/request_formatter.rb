# frozen_string_literal: false

module Dalli
  module Protocol
    class Meta
      ##
      # Class that encapsulates logic for formatting meta protocol requests
      # to memcached.
      ##
      class RequestFormatter
        # Since these are string construction methods, we're going to disable these
        # Rubocop directives.  We really can't make this construction much simpler,
        # and introducing an intermediate object seems like overkill.
        #
        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/ParameterLists
        # rubocop:disable Metrics/PerceivedComplexity
        #
        # Meta get flags:
        #
        # Thundering herd protection:
        # - vivify_ttl (N flag): On miss, create a stub item and return W flag. The TTL
        #   specifies how long the stub lives. Other clients see X (stale) and Z (lost race).
        # - recache_ttl (R flag): If item's remaining TTL is below this threshold, return W
        #   flag to indicate this client should recache. Other clients get Z (lost race).
        #
        # Metadata flags:
        # - return_hit_status (h flag): Return whether item has been hit before (0 or 1)
        # - return_last_access (l flag): Return seconds since item was last accessed
        # - skip_lru_bump (u flag): Don't bump item in LRU, don't update hit status or last access
        #
        # Response flags (parsed by response processor):
        # - W: Client won the right to recache this item
        # - X: Item is stale (another client is regenerating)
        # - Z: Client lost the recache race (another client is already regenerating)
        # - h0/h1: Hit status (0 = first access, 1 = previously accessed)
        # - l<N>: Seconds since last access
        def self.meta_get(key:, value: true, return_cas: false, ttl: nil, base64: false, quiet: false,
                          vivify_ttl: nil, recache_ttl: nil,
                          return_hit_status: false, return_last_access: false, skip_lru_bump: false,
                          skip_flags: false)
          cmd = "mg #{key}"
          # In raw mode (skip_flags: true), we don't request bitflags since they're not used.
          # This saves 2 bytes per request and skips parsing on response.
          cmd << (skip_flags ? ' v' : ' v f') if value
          cmd << ' c' if return_cas
          cmd << ' b' if base64
          cmd << " T#{ttl}" if ttl
          cmd << ' k q s' if quiet # Return the key in the response if quiet
          cmd << " N#{vivify_ttl}" if vivify_ttl # Thundering herd: vivify on miss
          cmd << " R#{recache_ttl}" if recache_ttl # Thundering herd: win recache if TTL below threshold
          cmd << ' h' if return_hit_status # Return hit status (0 or 1)
          cmd << ' l' if return_last_access # Return seconds since last access
          cmd << ' u' if skip_lru_bump # Don't bump LRU or update access stats
          cmd + TERMINATOR
        end

        def self.meta_set(key:, value:, bitflags: nil, cas: nil, ttl: nil, mode: :set, base64: false, quiet: false)
          cmd = "ms #{key} #{value.bytesize}"
          cmd << ' c' unless %i[append prepend].include?(mode)
          cmd << ' b' if base64
          cmd << " F#{bitflags}" if bitflags
          cmd << cas_string(cas)
          cmd << " T#{ttl}" if ttl
          cmd << " M#{mode_to_token(mode)}"
          cmd << ' q' if quiet
          cmd << TERMINATOR
        end

        # Thundering herd protection flag:
        # - stale (I flag): Instead of deleting the item, mark it as stale. Other clients
        #   using N/R flags will see the X flag and know the item is being regenerated.
        def self.meta_delete(key:, cas: nil, ttl: nil, base64: false, quiet: false, stale: false)
          cmd = "md #{key}"
          cmd << ' b' if base64
          cmd << cas_string(cas)
          cmd << " T#{ttl}" if ttl
          cmd << ' I' if stale # Mark stale instead of deleting
          cmd << ' q' if quiet
          cmd + TERMINATOR
        end

        def self.meta_arithmetic(key:, delta:, initial:, incr: true, cas: nil, ttl: nil, base64: false, quiet: false)
          cmd = "ma #{key} v"
          cmd << ' b' if base64
          cmd << " D#{delta}" if delta
          cmd << " J#{initial}" if initial
          # Always set a TTL if an initial value is specified
          cmd << " N#{ttl || 0}" if ttl || initial
          cmd << cas_string(cas)
          cmd << ' q' if quiet
          cmd << " M#{incr ? 'I' : 'D'}"
          cmd + TERMINATOR
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/ParameterLists
        # rubocop:enable Metrics/PerceivedComplexity

        def self.meta_noop
          "mn#{TERMINATOR}"
        end

        def self.version
          "version#{TERMINATOR}"
        end

        def self.flush(delay: nil, quiet: false)
          cmd = +'flush_all'
          cmd << " #{parse_to_64_bit_int(delay, 0)}" if delay
          cmd << ' noreply' if quiet
          cmd + TERMINATOR
        end

        ALLOWED_STATS_ARGS = [nil, '', 'items', 'slabs', 'settings', 'reset'].freeze

        def self.stats(arg = nil)
          raise ArgumentError, "Invalid stats argument: #{arg.inspect}" unless ALLOWED_STATS_ARGS.include?(arg)

          cmd = +'stats'
          cmd << " #{arg}" if arg && !arg.empty?
          cmd + TERMINATOR
        end

        def self.mode_to_token(mode)
          case mode
          when :add
            'E'
          when :replace
            'R'
          when :append
            'A'
          when :prepend
            'P'
          else
            'S'
          end
        end

        def self.cas_string(cas)
          cas = parse_to_64_bit_int(cas, nil)
          cas.nil? || cas.zero? ? '' : " C#{cas}"
        end

        def self.parse_to_64_bit_int(val, default)
          val.nil? ? nil : Integer(val)
        rescue ArgumentError
          # Sanitize to default if it isn't parsable as an integer
          default
        end
      end
    end
  end
end
