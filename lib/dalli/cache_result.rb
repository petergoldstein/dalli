# frozen_string_literal: true

module Dalli
  ##
  # An immutable, typed view over the Hash returned by Client#get_with_metadata
  # and Client#get_multi_with_metadata.
  #
  # This is an interim adapter (see #1130 / #1151): #get_with_metadata and
  # #get_multi_with_metadata keep returning a Hash for now, since changing
  # their return type is a breaking change reserved for a future major
  # version. #get_with_metadata_result and #get_multi_with_metadata_result
  # wrap that Hash in this type instead, so the structured shape can be
  # validated by callers ahead of that change.
  ##
  class CacheResult
    attr_reader :value, :cas, :hit_before, :last_access, :ttl_remaining

    # @param hash [Hash] a Hash as returned by Client#get_with_metadata, or a
    #   single value from the Hash returned by Client#get_multi_with_metadata
    def initialize(hash)
      @value = hash[:value]
      @cas = hash[:cas]
      @miss = hash.fetch(:miss, false)
      @stale = hash.fetch(:stale, false)
      @won_recache = hash.fetch(:won_recache, false)
      @lost_recache = hash.fetch(:lost_recache, false)
      @hit_before = hash[:hit_before]
      @last_access = hash[:last_access]
      @ttl_remaining = hash[:ttl_remaining]

      raise ArgumentError, 'a result cannot be both a miss and stale' if @miss && @stale

      freeze
    end

    # True when the key did not exist. Prefer this over a nil #value, which
    # cannot distinguish a miss from a stored nil under cache_nils.
    def miss?
      @miss
    end

    # The inverse of #miss?.
    def hit?
      !@miss
    end

    # True when the item is a tombstone (marked stale via the meta protocol's
    # invalidate flag) rather than removed. Not a miss: #value is still the
    # last-known value unless the tombstone also dropped it.
    def stale?
      @stale
    end

    # True if this call won the right to regenerate the value under
    # thundering-herd protection (see Client#fetch_with_lock).
    def won_recache?
      @won_recache
    end

    # True if another client already won the recache race for this key.
    def lost_recache?
      @lost_recache
    end
  end
end
