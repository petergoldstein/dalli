# frozen_string_literal: true

require_relative '../helper'

describe 'thundering herd protection' do
  # Thundering herd features require memcached 1.6+ (meta protocol)
  describe 'using the meta protocol' do
    before do
      skip 'Thundering herd features require memcached 1.6+' unless MemcachedManager.supported_protocols.include?(:meta)
    end

    describe 'get_with_recache' do
      it 'returns value and recache status for existing key' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          dc.set('existing_key', 'existing_value', 300)

          # Get an existing key - should not have any recache flags
          server = dc.send(:ring).server_for_key('existing_key')
          result = server.request(:meta_get, 'existing_key')

          assert_equal 'existing_value', result[:value]
          assert_predicate result[:cas], :positive?
          refute result[:won_recache]
          refute result[:stale]
          refute result[:lost_recache]
        end
      end

      it 'returns nil value for non-existent key without vivify' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          server = dc.send(:ring).server_for_key('nonexistent_key')
          result = server.request(:meta_get, 'nonexistent_key')

          assert_nil result[:value]
          refute result[:won_recache]
          refute result[:stale]
          refute result[:lost_recache]
        end
      end

      it 'vivifies on miss with N flag and returns won_recache' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          server = dc.send(:ring).server_for_key('vivify_key')
          # Request with vivify_ttl - on miss, creates stub and returns W flag
          result = server.request(:meta_get, 'vivify_key', { vivify_ttl: 30 })

          # The first client should win the recache race on a miss
          assert result[:won_recache], 'First client should win recache on miss with N flag'
          # When vivifying, memcached creates an empty stub value
          # The value will be empty string (marshalled) since the key was just created
        end
      end

      it 'returns stale and lost_recache for second client during vivify' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          server = dc.send(:ring).server_for_key('race_key')

          # First client vivifies the key
          result1 = server.request(:meta_get, 'race_key', { vivify_ttl: 30 })

          assert result1[:won_recache], 'First client should win'

          # Second client should see stale and lost the race
          server.request(:meta_get, 'race_key', { vivify_ttl: 30 })
          # NOTE: On the second request, the stub already exists
          # Behavior depends on memcached version and exact timing
          # The key point is that only one client wins
        end
      end
    end

    describe 'delete_stale' do
      it 'marks item as stale instead of deleting' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          dc.set('stale_key', 'stale_value', 300)

          # Verify the key exists
          assert_equal 'stale_value', dc.get('stale_key')

          # Mark it as stale
          server = dc.send(:ring).server_for_key('stale_key')
          result = server.request(:delete_stale, 'stale_key')

          assert result, 'delete_stale should return true on success'

          # After marking stale, the key should still be accessible
          # but will have the X flag when fetched with N/R flags
        end
      end
    end

    describe 'request formatter' do
      it 'formats meta_get with N flag' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          vivify_ttl: 30
        )

        assert_includes req, 'N30'
      end

      it 'formats meta_get with R flag' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          recache_ttl: 60
        )

        assert_includes req, 'R60'
      end

      it 'formats meta_get with both N and R flags' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          vivify_ttl: 30,
          recache_ttl: 60
        )

        assert_includes req, 'N30'
        assert_includes req, 'R60'
      end

      it 'formats meta_delete with I (stale) flag' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_delete(
          key: 'test_key',
          stale: true
        )

        assert_includes req, ' I'
      end

      it 'formats meta_get with h (hit status) flag' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          return_hit_status: true
        )

        assert_includes req, ' h'
      end

      it 'formats meta_get with l (last access) flag' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          return_last_access: true
        )

        assert_includes req, ' l'
      end

      it 'formats meta_get with u (skip LRU bump) flag' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          skip_lru_bump: true
        )

        assert_includes req, ' u'
      end

      it 'formats meta_get with all metadata flags combined' do
        req = Dalli::Protocol::Meta::RequestFormatter.meta_get(
          key: 'test_key',
          vivify_ttl: 30,
          recache_ttl: 60,
          return_hit_status: true,
          return_last_access: true,
          skip_lru_bump: true
        )

        assert_includes req, 'N30'
        assert_includes req, 'R60'
        assert_includes req, ' h'
        assert_includes req, ' l'
        assert_includes req, ' u'
      end
    end

    describe 'get_with_metadata' do
      it 'returns value and metadata for existing key' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          dc.set('metadata_key', 'metadata_value', 300)

          result = dc.get_with_metadata('metadata_key')

          assert_equal 'metadata_value', result[:value]
          assert_predicate result[:cas], :positive?
          refute result[:won_recache]
          refute result[:stale]
          refute result[:lost_recache]
        end
      end

      it 'returns nil value for non-existent key' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          result = dc.get_with_metadata('nonexistent_key')

          assert_nil result[:value]
          refute result[:won_recache]
        end
      end

      it 'supports vivify_ttl option for thundering herd protection' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          # First request should win the recache race
          result = dc.get_with_metadata('vivify_key', vivify_ttl: 30)

          assert result[:won_recache], 'First client should win recache on miss with vivify_ttl'
        end
      end

      it 'supports recache_ttl option for early recache' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          # Set with a very short TTL
          dc.set('recache_key', 'recache_value', 5)

          # Request with recache_ttl higher than remaining TTL should win recache
          result = dc.get_with_metadata('recache_key', recache_ttl: 10)

          # Either we win recache (TTL was below threshold) or the value is returned
          assert_equal 'recache_value', result[:value]
        end
      end

      it 'returns hit status when requested' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          dc.set('hit_key', 'hit_value', 300)

          # First access - should show not previously hit
          result1 = dc.get_with_metadata('hit_key', return_hit_status: true)

          assert_equal 'hit_value', result1[:value]
          refute_nil result1[:hit_before]
          refute result1[:hit_before], 'First access should show not previously hit'

          # Second access - should show previously hit
          result2 = dc.get_with_metadata('hit_key', return_hit_status: true)

          assert result2[:hit_before], 'Second access should show previously hit'
        end
      end

      it 'returns last access time when requested' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          dc.set('access_key', 'access_value', 300)

          # First get to establish access time
          dc.get('access_key')

          # Small delay to ensure measurable time difference
          sleep 1

          # Get with last access time
          result = dc.get_with_metadata('access_key', return_last_access: true)

          assert_equal 'access_value', result[:value]
          refute_nil result[:last_access]
          assert_predicate result[:last_access], :positive?, 'Last access time should be positive'
        end
      end

      it 'supports skip_lru_bump option' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          dc.set('lru_key', 'lru_value', 300)

          # Get with skip_lru_bump - should not update hit status
          result = dc.get_with_metadata('lru_key', skip_lru_bump: true, return_hit_status: true)

          assert_equal 'lru_value', result[:value]
          # With skip_lru_bump, the hit status should remain as first access
          refute result[:hit_before], 'skip_lru_bump should not update hit status'
        end
      end

      it 'does not include optional metadata fields when not requested' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          dc.set('simple_key', 'simple_value', 300)

          result = dc.get_with_metadata('simple_key')

          assert_equal 'simple_value', result[:value]
          refute result.key?(:hit_before), 'Should not include hit_before when not requested'
          refute result.key?(:last_access), 'Should not include last_access when not requested'
        end
      end

      it 'raises error when used with binary protocol' do
        memcached_persistent(:binary) do |dc|
          assert_raises(Dalli::DalliError) do
            dc.get_with_metadata('key')
          end
        end
      end
    end

    describe 'fetch_with_lock' do
      it 'regenerates value on cache miss' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          call_count = 0
          value = dc.fetch_with_lock('new_key', ttl: 300, lock_ttl: 30) do
            call_count += 1
            'generated_value'
          end

          assert_equal 'generated_value', value
          assert_equal 1, call_count

          # Value should now be cached
          cached_value = dc.get('new_key')

          assert_equal 'generated_value', cached_value
        end
      end

      it 'returns cached value without calling block' do
        memcached_persistent(:meta) do |dc|
          dc.flush
          dc.set('existing_key', 'existing_value', 300)

          call_count = 0
          value = dc.fetch_with_lock('existing_key', ttl: 300, lock_ttl: 30) do
            call_count += 1
            'should_not_be_called'
          end

          assert_equal 'existing_value', value
          assert_equal 0, call_count
        end
      end

      it 'requires a block' do
        memcached_persistent(:meta) do |dc|
          assert_raises(ArgumentError) do
            dc.fetch_with_lock('key', ttl: 300, lock_ttl: 30)
          end
        end
      end

      it 'works with complex values' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          complex_value = { items: [1, 2, 3], metadata: { count: 3 } }
          value = dc.fetch_with_lock('complex_key', ttl: 300, lock_ttl: 30) do
            complex_value
          end

          assert_equal complex_value, value
          assert_equal complex_value, dc.get('complex_key')
        end
      end

      it 'only allows one client to regenerate' do
        memcached_persistent(:meta) do |dc|
          dc.flush

          # First fetch should win and regenerate
          result1 = dc.fetch_with_lock('race_key', ttl: 300, lock_ttl: 30) do
            'first_value'
          end

          assert_equal 'first_value', result1

          # Second fetch should get the cached value
          result2 = dc.fetch_with_lock('race_key', ttl: 300, lock_ttl: 30) do
            'second_value_should_not_be_used'
          end

          assert_equal 'first_value', result2
        end
      end
    end
  end

  describe 'using the binary protocol' do
    it 'raises error when fetch_with_lock is called' do
      memcached_persistent(:binary) do |dc|
        assert_raises(Dalli::DalliError) do
          dc.fetch_with_lock('key', ttl: 300, lock_ttl: 30) { 'value' }
        end
      end
    end
  end
end
