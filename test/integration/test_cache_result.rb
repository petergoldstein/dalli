# frozen_string_literal: true

require_relative '../helper'

describe 'CacheResult adapter methods' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      def tombstone(port, key, ttl: 30)
        sock = TCPSocket.new('127.0.0.1', port)
        sock.write("md #{key} I T#{ttl}\r\n")
        response = sock.gets("\r\n").to_s.chomp
        sock.close
        raise "unexpected md response: #{response.inspect}" unless response == 'HD'
      end

      describe '#get_with_metadata_result' do
        it 'returns a CacheResult for a hit' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'val_a')

            result = dc.get_with_metadata_result('a')

            assert_kind_of Dalli::CacheResult, result
            assert_equal 'val_a', result.value
            assert_predicate result, :hit?
            refute_predicate result, :miss?
          end
        end

        it 'returns a CacheResult for a miss' do
          memcached_persistent(p) do |dc|
            dc.flush

            result = dc.get_with_metadata_result('absent')

            assert_predicate result, :miss?
            refute_predicate result, :hit?
            assert_nil result.value
          end
        end

        it 'passes through return_hit_status/return_last_access/return_ttl_remaining' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'val_a', 100)
            dc.get('a') # bump hit status

            result = dc.get_with_metadata_result('a', return_hit_status: true, return_last_access: true,
                                                      return_ttl_remaining: true)

            assert result.hit_before
            assert_operator result.last_access, :>=, 0
            assert_operator result.ttl_remaining, :>, 0
          end
        end

        it 'reports a tombstoned item as stale rather than missing' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('tomb', 'original')
            tombstone(port, 'tomb')

            result = dc.get_with_metadata_result('tomb')

            assert_predicate result, :stale?
            refute_predicate result, :miss?
            assert_equal 'original', result.value
          end
        end
      end

      describe '#get_multi_with_metadata_result' do
        it 'returns a Hash of CacheResult for the keys found' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'val_a')
            dc.set('b', 'val_b')

            results = dc.get_multi_with_metadata_result(%w[a b absent])

            assert_equal %w[a b], results.keys.sort
            assert_kind_of Dalli::CacheResult, results['a']
            assert_equal 'val_a', results['a'].value
            refute results.key?('absent')
          end
        end

        it 'reports a tombstoned item as stale rather than missing' do
          memcached_persistent(p) do |_dc, port|
            dc = single_server_client(port)
            dc.flush
            dc.set('tomb', 'original')
            dc.set('fresh', 'untouched')
            tombstone(port, 'tomb')

            results = dc.get_multi_with_metadata_result(%w[tomb fresh])

            assert_predicate results['tomb'], :stale?
            refute_predicate results['tomb'], :miss?
            refute_predicate results['fresh'], :stale?
          end
        end

        it 'returns an empty hash for no keys' do
          memcached_persistent(p) do |dc|
            assert_empty dc.get_multi_with_metadata_result([])
          end
        end

        it 'forwards req_options to #get_multi_with_metadata' do
          memcached_persistent(p) do |dc|
            dc.flush
            dc.set('a', 'va')

            results = dc.get_multi_with_metadata_result('a', req_options: { p_token: 'pod1' })

            assert_equal ['a'], results.keys
            assert_equal 'va', results['a'].value

            # Reaching routing-token validation proves the options weren't
            # swallowed as an extra key
            assert_raises(ArgumentError) do
              dc.get_multi_with_metadata_result('a', req_options: { p_token: "pod1\r\nflush_all" })
            end
          end
        end
      end
    end
  end
end
