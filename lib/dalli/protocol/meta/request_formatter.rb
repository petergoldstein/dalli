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
        # rubocop:disable Metrics/MethodLength
        # rubocop:disable Metrics/ParameterLists
        # rubocop:disable Metrics/PerceivedComplexity
        def self.meta_get(key:, value: true, return_cas: false, ttl: nil, base64: false, quiet: false)
          cmd = "mg #{key}"
          cmd << ' v f' if value
          cmd << ' c' if return_cas
          cmd << ' b' if base64
          cmd << " T#{integer_flag(:ttl, ttl)}" if ttl
          cmd << ' k q s' if quiet # Return the key in the response if quiet
          cmd + TERMINATOR
        end

        def self.meta_set(key:, value:, bitflags: nil, cas: nil, ttl: nil, mode: :set, base64: false, quiet: false)
          cmd = "ms #{key} #{value.bytesize}"
          cmd << ' c' unless %i[append prepend].include?(mode)
          cmd << ' b' if base64
          cmd << " F#{bitflags}" if bitflags
          cmd << cas_string(cas)
          cmd << " T#{integer_flag(:ttl, ttl)}" if ttl
          cmd << " M#{mode_to_token(mode)}"
          cmd << ' q' if quiet
          cmd << TERMINATOR
          cmd << value
          cmd + TERMINATOR
        end

        def self.meta_delete(key:, cas: nil, ttl: nil, base64: false, quiet: false)
          cmd = "md #{key}"
          cmd << ' b' if base64
          cmd << cas_string(cas)
          cmd << " T#{integer_flag(:ttl, ttl)}" if ttl
          cmd << ' q' if quiet
          cmd + TERMINATOR
        end

        def self.meta_arithmetic(key:, delta:, initial:, incr: true, cas: nil, ttl: nil, base64: false, quiet: false)
          cmd = "ma #{key} v"
          cmd << ' b' if base64
          cmd << " D#{integer_flag(:delta, delta)}" if delta
          cmd << " J#{integer_flag(:initial, initial)}" if initial
          # Always set a TTL if an initial value is specified
          cmd << " N#{ttl ? integer_flag(:ttl, ttl) : 0}" if ttl || initial
          cmd << cas_string(cas)
          cmd << ' q' if quiet
          cmd << " M#{incr ? 'I' : 'D'}"
          cmd + TERMINATOR
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/MethodLength
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

        def self.stats(arg = nil)
          cmd = +'stats'
          cmd << " #{arg}" if arg
          cmd + TERMINATOR
        end

        # rubocop:disable Metrics/MethodLength
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
        # rubocop:enable Metrics/MethodLength

        # Numeric flag values are written straight into the command line, so a
        # value that isn't an integer -- e.g. a String carrying CRLF -- would let
        # the caller inject further memcached commands (GHSA-6wmv-xq9m-fmp7).
        # Converting to Integer means only digits ever reach the wire. Strings
        # are parsed as base 10 so "010" means 10, as memcached would read it,
        # rather than octal 8.
        def self.integer_flag(name, value)
          value.is_a?(String) ? Integer(value, 10) : Integer(value)
        rescue ArgumentError, TypeError, FloatDomainError
          raise ArgumentError, "#{name} must be an Integer, got #{value.inspect}"
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
