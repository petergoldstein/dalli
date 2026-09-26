# frozen_string_literal: true

require_relative 'helper'

describe Dalli::CacheResult do
  describe 'a hit' do
    let(:result) do
      Dalli::CacheResult.new(value: 'v', cas: 42, miss: false, stale: false,
                             won_recache: false, lost_recache: false)
    end

    it 'exposes value and cas' do
      assert_equal 'v', result.value
      assert_equal 42, result.cas
    end

    it 'is a hit, not a miss' do
      refute_predicate result, :miss?
      assert_predicate result, :hit?
    end

    it 'is not stale' do
      refute_predicate result, :stale?
    end

    it 'did not win or lose a recache race' do
      refute_predicate result, :won_recache?
      refute_predicate result, :lost_recache?
    end

    it 'has no hit-status/last-access/ttl-remaining metadata unless requested' do
      assert_nil result.hit_before
      assert_nil result.last_access
      assert_nil result.ttl_remaining
    end

    it 'is frozen' do
      assert_predicate result, :frozen?
    end
  end

  describe 'a miss' do
    let(:result) { Dalli::CacheResult.new(value: nil, cas: 0, miss: true, stale: false) }

    it 'is a miss, not a hit' do
      assert_predicate result, :miss?
      refute_predicate result, :hit?
    end

    it 'has a nil value' do
      assert_nil result.value
    end
  end

  describe 'a tombstoned (stale) item' do
    let(:result) { Dalli::CacheResult.new(value: 'original', cas: 7, miss: false, stale: true) }

    it 'is stale but not a miss' do
      assert_predicate result, :stale?
      refute_predicate result, :miss?
      assert_predicate result, :hit?
    end

    it 'still exposes the last-known value' do
      assert_equal 'original', result.value
    end
  end

  describe 'thundering-herd metadata' do
    it 'exposes won_recache' do
      result = Dalli::CacheResult.new(value: 'v', cas: 1, miss: false, stale: false, won_recache: true)

      assert_predicate result, :won_recache?
      refute_predicate result, :lost_recache?
    end

    it 'exposes lost_recache' do
      result = Dalli::CacheResult.new(value: 'v', cas: 1, miss: false, stale: false, lost_recache: true)

      assert_predicate result, :lost_recache?
      refute_predicate result, :won_recache?
    end
  end

  describe 'optional metadata' do
    it 'passes through hit_before, last_access, and ttl_remaining when present' do
      result = Dalli::CacheResult.new(value: 'v', cas: 1, miss: false, stale: false,
                                      hit_before: true, last_access: 42, ttl_remaining: 100)

      assert result.hit_before
      assert_equal 42, result.last_access
      assert_equal 100, result.ttl_remaining
    end
  end

  describe 'invariant enforcement' do
    # A tombstoned item is a hit at the protocol level (VA/HD with the X
    # flag); a true miss answers EN and never carries X. A result claiming
    # both is not a state the protocol can produce, so construction rejects
    # it rather than silently picking one.
    it 'rejects a result that is both a miss and stale' do
      error = assert_raises(ArgumentError) do
        Dalli::CacheResult.new(value: nil, cas: 0, miss: true, stale: true)
      end

      assert_equal 'a result cannot be both a miss and stale', error.message
    end
  end

  describe 'defaults' do
    it 'treats miss, stale, won_recache, and lost_recache as false when absent from the hash' do
      result = Dalli::CacheResult.new(value: 'v', cas: 1)

      refute_predicate result, :miss?
      refute_predicate result, :stale?
      refute_predicate result, :won_recache?
      refute_predicate result, :lost_recache?
    end
  end
end
