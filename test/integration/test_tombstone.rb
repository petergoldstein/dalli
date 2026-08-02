# frozen_string_literal: true

require_relative '../helper'

# Integration tests for memcached tombstone support: the meta-protocol's
# `I` (mark stale), `T` (tombstone TTL on delete), and `x` (drop value)
# flags on `md`, plus the `X` response flag on `mg` exposed via
# Client#get_with_metadata.
#
# A tombstoned item lives briefly in a "stale" window where reads can tell
# a racing repopulator from a true miss — caller checks result[:stale] vs
# result[:miss]. Designed for high-concurrency invalidation scenarios where
# a hard delete would let an in-flight request rewrite a stale value over
# the deleted key.
describe 'tombstone (mark-stale) support' do
  describe 'Client#get_with_metadata return shape' do
    it 'returns a metadata Hash for a normal hit' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk', 'val'))

        result = dc.get_with_metadata('tk')

        assert_kind_of Hash, result
        assert_equal 'val', result[:value]
        refute result[:miss]
        refute result[:miss]
        refute result[:stale]
      end
    end

    it 'returns miss? on a true miss (key never existed)' do
      memcached_persistent do |dc|
        dc.flush

        result = dc.get_with_metadata('absent')

        assert_kind_of Hash, result
        assert_nil result[:value]
        assert result[:miss]
        assert result[:miss]
        refute result[:stale]
      end
    end

    it 'returns miss? after a regular (non-tombstone) delete' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk', 'val'))
        dc.delete('tk')

        result = dc.get_with_metadata('tk')

        assert result[:miss]
        refute result[:stale]
      end
    end

    it 'returns a hash containing the value, cas and stale/miss markers' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('tk', 'val')

        result = dc.get_with_metadata('tk')

        assert_equal 'val', result[:value]
        assert_operator result[:cas], :>, 0
        assert_includes result, :stale
        assert_includes result, :miss
      end
    end

    # Pins the three-state contract: callers branch on miss?/stale?/hit?,
    # never on value.nil? — because a legitimately cached nil is a hit.
    it 'distinguishes a cached nil (hit?), an absent key (miss?), and a tombstone (stale?)' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk-nil', nil))
        cached_nil = dc.get_with_metadata('tk-nil')

        refute cached_nil[:miss]
        refute cached_nil[:miss]
        refute cached_nil[:stale]
        assert_nil cached_nil[:value]

        absent = dc.get_with_metadata('tk-absent')

        assert absent[:miss]
        assert absent[:miss]
        refute absent[:stale]
        assert_nil absent[:value]

        assert op_addset_succeeds(dc.set('tk-tomb', 'val'))
        dc.delete('tk-tomb', invalidate: true, tombstone_ttl: 30)
        tombstoned = dc.get_with_metadata('tk-tomb')

        assert tombstoned[:stale]
        refute tombstoned[:miss]
        refute tombstoned[:miss]
      end
    end
  end

  describe 'Client#get_multi_with_metadata return shape' do
    it 'returns metadata Hashes for normal hits, stale tombstones, dropped tombstones, and misses' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('multi-hit', 'hit-val'))
        assert op_addset_succeeds(dc.set('multi-stale', 'stale-val'))
        assert op_addset_succeeds(dc.set('multi-dropped', 'dropped-val'))
        dc.delete('multi-stale', invalidate: true, tombstone_ttl: 30)
        dc.delete('multi-dropped', invalidate: true, drop_value: true, tombstone_ttl: 30)

        results = dc.get_multi_with_metadata('multi-hit', 'multi-stale', 'multi-dropped', 'multi-absent')

        assert_equal %w[multi-absent multi-dropped multi-hit multi-stale], results.keys.sort

        hit = results['multi-hit']

        assert_kind_of Hash, hit
        assert_equal 'hit-val', hit[:value]
        refute hit[:miss]
        refute hit[:miss]
        refute hit[:stale]

        stale = results['multi-stale']

        assert_kind_of Hash, stale
        assert_equal 'stale-val', stale[:value]
        refute stale[:miss]
        refute stale[:miss]
        assert stale[:stale]

        dropped = results['multi-dropped']

        assert_kind_of Hash, dropped
        assert_equal '', dropped[:value]
        refute dropped[:miss]
        refute dropped[:miss]
        assert dropped[:stale]

        absent = results['multi-absent']

        assert_kind_of Hash, absent
        assert_nil absent[:value]
        assert absent[:miss]
        assert absent[:miss]
        refute absent[:stale]
      end
    end

    it 'returns results under original keys when keys require base64 encoding' do
      memcached_persistent do |dc|
        dc.flush

        unicode_key = 'multi-ƒ©åÍÎ'
        space_key = 'multi space'
        crlf_key = "multi-crlf\r\nkey"
        absent_key = "multi-absent\r\nkey"

        assert op_addset_succeeds(dc.set(unicode_key, 'unicode-val'))
        assert op_addset_succeeds(dc.set(space_key, 'space-val'))
        assert op_addset_succeeds(dc.set(crlf_key, 'crlf-val'))
        dc.delete(unicode_key, invalidate: true, tombstone_ttl: 30)

        results = dc.get_multi_with_metadata(space_key, unicode_key, crlf_key, absent_key)

        assert_equal [absent_key, crlf_key, space_key, unicode_key].sort, results.keys.sort
        assert_equal 'space-val', results[space_key][:value]
        assert_equal 'crlf-val', results[crlf_key][:value]
        assert_equal 'unicode-val', results[unicode_key][:value]
        refute results[space_key][:miss]
        refute results[crlf_key][:miss]
        assert results[unicode_key][:stale]
        assert results[absent_key][:miss]
      end
    end

    it 'yields a metadata Hash for every requested key in block form' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('multi-block-hit', 'hit-val'))

        seen = {}
        dc.get_multi_with_metadata('multi-block-hit', 'multi-block-absent') do |key, result|
          seen[key] = result
        end

        assert_equal %w[multi-block-absent multi-block-hit], seen.keys.sort
        assert_equal 'hit-val', seen['multi-block-hit'][:value]
        refute seen['multi-block-hit'][:miss]
        assert seen['multi-block-absent'][:miss]
      end
    end
  end

  describe 'delete with drop_value only' do
    it 'drops the value without marking the item stale' do
      memcached_persistent do |dc|
        dc.flush

        # Use a non-raw value so this also proves the zero-byte response from
        # `md ... x` does not try to unmarshal the previously serialized value.
        assert op_addset_succeeds(dc.set('tk-x-only', { payload: 'should-be-dropped' }))

        assert dc.delete('tk-x-only', drop_value: true)
        result = dc.get_with_metadata('tk-x-only')

        refute result[:miss]
        refute result[:stale]
        refute result[:miss]
        assert_equal '', result[:value]
        assert_equal '', dc.get('tk-x-only')
      end
    end
  end

  describe 'delete with invalidate: true' do
    it 'leaves the item readable but marked stale' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk', 'preserved-val'))

        dc.delete('tk', invalidate: true)
        result = dc.get_with_metadata('tk')

        assert result[:stale], 'expected X flag (stale) after invalidate'
        refute result[:miss], 'invalidate without drop_value should leave value readable'
        refute result[:miss]
        assert_equal 'preserved-val', result[:value]
      end
    end

    it 'leaves an empty value when drop_value is also set' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk', 'should-be-dropped'))

        dc.delete('tk', invalidate: true, drop_value: true)
        result = dc.get_with_metadata('tk')

        assert result[:stale]
        refute result[:miss]
        # Value is dropped — empty string, not the original
        assert_equal '', result[:value]
      end
    end

    it 'transitions from stale? to miss? after tombstone_ttl elapses' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk', 'val'))

        dc.delete('tk', invalidate: true, tombstone_ttl: 1, drop_value: true)

        # Within the tombstone window
        assert dc.get_with_metadata('tk')[:stale]

        # Past the tombstone window, the X flag should be gone
        sleep 2
        result = dc.get_with_metadata('tk')

        assert result[:miss], 'tombstone should have expired into a true miss'
        refute result[:stale]
      end
    end

    it 'sanitizes long tombstone_ttl intervals before sending to memcached' do
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('tk-long-ttl', 'val'))

        long_ttl = Dalli::Protocol::TtlSanitizer::MAX_ACCEPTABLE_EXPIRATION_INTERVAL + 1
        dc.delete('tk-long-ttl', invalidate: true, tombstone_ttl: long_ttl)

        assert dc.get_with_metadata('tk-long-ttl')[:stale]
      end
    end

    it 'does not emit a tombstone for a plain delete' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('tk', 'val')

        dc.delete('tk') # no kwargs — regular hard delete
        result = dc.get_with_metadata('tk')

        assert result[:miss]
        refute result[:stale]
      end
    end

    it 'is reachable via delete_cas with explicit cas' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('tk', 'val')
        cas = dc.get_cas('tk').last

        dc.delete_cas('tk', cas, invalidate: true, tombstone_ttl: 30)

        assert dc.get_with_metadata('tk')[:stale]
      end
    end
  end

  describe 'delete_multi with invalidate' do
    it 'tombstones every key in the batch' do
      memcached_persistent do |dc|
        dc.flush
        keys = %w[tm-a tm-b tm-c]
        keys.each { |k| dc.set(k, "val-#{k}") }

        deleted = dc.delete_multi(keys, invalidate: true, tombstone_ttl: 30)

        assert_equal keys.length, deleted
        keys.each do |k|
          result = dc.get_with_metadata(k)

          assert result[:stale], "expected #{k} to be stale after delete_multi(invalidate: true)"
          assert_equal "val-#{k}", result[:value]
        end
      end
    end

    it 'drops values across the batch when drop_value is set' do
      memcached_persistent do |dc|
        dc.flush
        keys = %w[tm-x tm-y]
        keys.each { |k| dc.set(k, 'orig') }

        dc.delete_multi(keys, invalidate: true, tombstone_ttl: 30, drop_value: true)

        keys.each do |k|
          result = dc.get_with_metadata(k)

          assert result[:stale]
          assert_equal '', result[:value]
        end
      end
    end
  end

  describe 'argument validation' do
    it 'raises ArgumentError when tombstone_ttl is supplied without invalidate' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('tk', 'val')

        with_nil_logger do
          assert_raises(ArgumentError) do
            dc.delete('tk', tombstone_ttl: 30)
          end
        end
      end
    end
  end

  describe 'interaction with quiet block' do
    it 'allows tombstone delete inside quiet (delete is in ALLOWED_QUIET_OPS)' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('tq', 'val')

        dc.quiet do
          dc.delete('tq', invalidate: true, tombstone_ttl: 30)
        end

        # Outside the quiet block, the tombstone should be visible
        assert dc.get_with_metadata('tq')[:stale]
      end
    end

    it 'raises NotPermittedMultiOpError when get_with_metadata is called inside quiet' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('tq', 'val')

        assert_raises(Dalli::NotPermittedMultiOpError) do
          dc.quiet do
            dc.get_with_metadata('tq')
          end
        end
      end
    end
  end
end
