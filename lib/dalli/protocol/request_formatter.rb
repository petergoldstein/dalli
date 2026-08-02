# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      ##
      # Class that encapsulates logic for formatting meta protocol requests
      # to memcached.
      ##
      module RequestFormatter
        extend self

        # Since these are string construction methods, we're going to disable these
        # Rubocop directives.  We really can't make this construction much simpler,
        # and introducing an intermediate object seems like overkill.
        #
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
        def meta_get(key:, value: true, return_cas: false, ttl: nil, quiet: false,
                     vivify_ttl: nil, recache_ttl: nil,
                     return_hit_status: false, return_last_access: false, return_ttl_remaining: false,
                     skip_lru_bump: false, skip_flags: false, p_token: nil, l_token: nil)
          cmd = "mg #{encoded_key(key)}"
          # In raw mode (skip_flags: true), we don't request bitflags since they're not used.
          # This saves 2 bytes per request and skips parsing on response.
          cmd << (skip_flags ? ' v' : ' v f') if value
          cmd << ' c' if return_cas
          cmd << " T#{ttl}" if ttl
          cmd << routing_tokens(p_token: p_token, l_token: l_token)
          cmd << ' k q s' if quiet # Return the key in the response if quiet
          cmd << " N#{vivify_ttl}" if vivify_ttl # Thundering herd: vivify on miss
          cmd << " R#{recache_ttl}" if recache_ttl # Thundering herd: win recache if TTL below threshold
          cmd << ' h' if return_hit_status # Return hit status (0 or 1)
          cmd << ' l' if return_last_access # Return seconds since last access
          cmd << ' t' if return_ttl_remaining # Return seconds of TTL remaining (-1 = no TTL)
          cmd << ' u' if skip_lru_bump # Don't bump LRU or update access stats
          cmd << TERMINATOR
        end

        def multi_meta_get(keys, skip_flags: false, return_cas: false, p_token: nil, l_token: nil)
          # In raw mode: "mg <key> v k q s\r\n" (no f flag, key at index 2)
          # Normal mode: "mg <key> v f k q s\r\n" (key at index 3)
          # With return_cas: a "c" flag is added after the value/bitflag flags.
          routing = routing_tokens(p_token: p_token, l_token: l_token)
          post_get = +' v'
          post_get << ' f' unless skip_flags
          post_get << ' c' if return_cas
          post_get << ' k q s' << routing << TERMINATOR
          buffer = ''.b
          keys.each do |key|
            buffer << 'mg ' << encoded_key(key) << post_get
          end
          buffer << 'mn' << TERMINATOR
        end

        def meta_set(key:, value:, bitflags: nil, cas: nil, ttl: nil, mode: :set, quiet: false,
                     p_token: nil, l_token: nil)
          base64 = KeyRegularizer.required?(key)
          key = KeyRegularizer.encode(key) if base64
          cmd = "ms #{key} #{value.bytesize}"
          # Skip the cas-return flag in quiet mode: the response is suppressed,
          # so requesting it only adds bytes to the request.
          cmd << ' c' if !quiet && !%i[append prepend].include?(mode)
          cmd << ' b' if base64
          cmd << " F#{bitflags}" if bitflags
          cmd << cas_string(cas)
          cmd << " T#{ttl}" if ttl
          cmd << " M#{mode_to_token(mode)}"
          cmd << ' q' if quiet
          cmd << routing_tokens(p_token: p_token, l_token: l_token)
          cmd << TERMINATOR
        end

        def multi_meta_set(entries, ttl: nil, p_token: nil, l_token: nil)
          routing = routing_tokens(p_token: p_token, l_token: l_token)
          buffer = ''.b
          entries.each do |key, pair|
            value, bitflags = pair

            base64 = KeyRegularizer.required?(key)
            key = KeyRegularizer.encode(key) if base64

            # Inline format: "ms <key> <size> c [b] F<flags> T<ttl> MS q [P<t>] [L<t>]\r\n"
            buffer << "ms #{key} #{value.bytesize} c"
            buffer << ' b' if base64
            buffer << " F#{bitflags}" if bitflags
            buffer << " T#{ttl}" if ttl
            buffer << ' MS q' << routing << TERMINATOR << value << TERMINATOR
          end
          buffer << META_NOOP
        end

        # Tombstone / thundering herd protection flags:
        # - stale / invalidate (I flag): Instead of deleting the item, mark it as stale.
        #   Readers using N/R flags (or get_with_metadata) will see the X flag and know
        #   the item is being regenerated.
        # - tombstone_ttl (T flag): how long the stale tombstone lives; requires invalidate.
        # - drop_value (x flag): remove the item value but leave the (stale) marker.
        def meta_delete(key:, cas: nil, ttl: nil, quiet: false, stale: false,
                        invalidate: false, tombstone_ttl: nil, drop_value: false,
                        p_token: nil, l_token: nil)
          raise ArgumentError, 'tombstone_ttl requires invalidate: true' if tombstone_ttl && !(invalidate || stale)

          cmd = "md #{encoded_key(key)}"
          cmd << cas_string(cas)
          cmd << " T#{ttl}" if ttl
          cmd << ' I' if stale || invalidate # Mark stale instead of deleting
          cmd << " T#{Integer(tombstone_ttl)}" if tombstone_ttl
          cmd << ' x' if drop_value # Drop the value but keep the item
          cmd << ' q' if quiet
          cmd << routing_tokens(p_token: p_token, l_token: l_token)
          cmd << TERMINATOR
        end

        def multi_meta_delete(keys, invalidate: false, tombstone_ttl: nil, drop_value: false,
                              p_token: nil, l_token: nil)
          raise ArgumentError, 'tombstone_ttl requires invalidate: true' if tombstone_ttl && !invalidate

          suffix = +' q'
          suffix << ' I' if invalidate
          suffix << " T#{Integer(tombstone_ttl)}" if tombstone_ttl
          suffix << ' x' if drop_value
          suffix << routing_tokens(p_token: p_token, l_token: l_token)
          suffix << TERMINATOR
          buffer = ''.b
          keys.each do |key|
            buffer << 'md ' << encoded_key(key) << suffix
          end
          buffer << META_NOOP
        end

        def meta_arithmetic(key:, delta:, initial:, incr: true, cas: nil, ttl: nil, quiet: false,
                            p_token: nil, l_token: nil)
          cmd = "ma #{encoded_key(key)} v"
          cmd << " D#{delta}" if delta
          cmd << " J#{initial}" if initial
          # Always set a TTL if an initial value is specified
          cmd << " N#{ttl || 0}" if ttl || initial
          cmd << cas_string(cas)
          cmd << ' q' if quiet
          cmd << " M#{incr ? 'I' : 'D'}"
          cmd << routing_tokens(p_token: p_token, l_token: l_token)
          cmd << TERMINATOR
        end

        # Builds the wire-format suffix for opaque routing tokens (P and L).
        #
        # Empty / nil tokens are treated as no-ops. CRLF and null bytes are
        # rejected with `ArgumentError` to prevent the token from being used
        # as a wire-protocol injection vector (e.g. `"foo\r\nflush_all\r\n"`
        # would otherwise be parsed as a second command by memcached or any
        # intermediate proxy/LB).
        def routing_tokens(p_token: nil, l_token: nil)
          p_token = nil if p_token.respond_to?(:empty?) && p_token.empty?
          l_token = nil if l_token.respond_to?(:empty?) && l_token.empty?
          validate_routing_token!('p_token', p_token)
          validate_routing_token!('l_token', l_token)
          return '' unless p_token || l_token

          s = +''
          s << " P#{p_token}" if p_token
          s << " L#{l_token}" if l_token
          s
        end

        # Disallowed bytes: CR, LF, NUL. Any of these embedded in a routing
        # token would let the caller inject a second wire-protocol command
        # (e.g. `"foo\r\nflush_all\r\n"`).
        #
        # Despite intuition, `match?` with a literal regex is ~2.3x faster
        # than `s.include?("\r") || s.include?("\n") || s.include?("\0")`
        # in microbenchmarks for short clean tokens (the hot path). Ruby's
        # Regexp engine fuses short character classes into a single C-level
        # scan, while the include? chain walks the string up to three times.
        ROUTING_TOKEN_FORBIDDEN = /[\r\n\0]/
        private_constant :ROUTING_TOKEN_FORBIDDEN

        def validate_routing_token!(name, value)
          return if value.nil?
          raise ArgumentError, "#{name} must be a String, got #{value.class}" unless value.is_a?(String)
          raise ArgumentError, "#{name} must not contain CRLF or null bytes" if value.match?(ROUTING_TOKEN_FORBIDDEN)
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/ParameterLists
        # rubocop:enable Metrics/PerceivedComplexity

        META_NOOP = "mn#{TERMINATOR}".freeze
        def meta_noop
          META_NOOP
        end

        def version
          "version#{TERMINATOR}"
        end

        def flush(delay: nil, quiet: false)
          cmd = +'flush_all'
          cmd << " #{parse_to_64_bit_int(delay, 0)}" if delay
          cmd << ' noreply' if quiet
          cmd << TERMINATOR
        end

        ALLOWED_STATS_ARGS = [nil, '', 'items', 'slabs', 'settings', 'reset'].freeze

        def stats(arg = nil)
          raise ArgumentError, "Invalid stats argument: #{arg.inspect}" unless ALLOWED_STATS_ARGS.include?(arg)

          cmd = +'stats'
          cmd << " #{arg}" if arg && !arg.empty?
          cmd << TERMINATOR
        end

        def encoded_key(key)
          if KeyRegularizer.required?(key)
            KeyRegularizer.encode(key) << ' b'
          else
            key
          end
        end

        private

        def mode_to_token(mode)
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

        def cas_string(cas)
          cas = parse_to_64_bit_int(cas, nil)
          cas.nil? || cas.zero? ? '' : " C#{cas}"
        end

        def parse_to_64_bit_int(val, default)
          val.nil? ? nil : Integer(val)
        rescue ArgumentError
          # Sanitize to default if it isn't parsable as an integer
          default
        end
      end
    end
  end
end
