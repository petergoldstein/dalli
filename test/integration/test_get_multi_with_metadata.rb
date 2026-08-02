# frozen_string_literal: true

require_relative '../helper'

describe 'get_multi_with_metadata' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      # Marks an item stale at the wire level. The client-side API for this
      # (delete with invalidate) is not implemented yet, but the read path has to
      # handle tombstones correctly now, since telling them apart from misses is
      # the reason this method exists.
      def tombstone(port, key, ttl: 30)
        sock = TCPSocket.new('127.0.0.1', port)
        sock.write("md #{key} I T#{ttl}\r\n")
        response = sock.gets("\r\n").to_s.chomp
        sock.close
        raise "unexpected md response: #{response.inspect}" unless response == 'HD'
      end

      it 'returns value, cas and stale for each key found' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('a', 'val_a')
          dc.set('b', 'val_b')

          result = dc.get_multi_with_metadata(%w[a b])

          assert_equal %w[a b], result.keys.sort
          assert_equal 'val_a', result['a'][:value]
          assert_operator result['a'][:cas], :positive?
          refute result['a'][:stale]
          # Present and false rather than absent, so the entry shape matches
          # get_with_metadata and stays stable if misses are ever included.
          assert result['a'].key?(:miss)
          refute result['a'][:miss]
        end
      end

      it 'omits keys that were not found' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('present', 'v')

          result = dc.get_multi_with_metadata(%w[present absent other_absent])

          assert_equal ['present'], result.keys
          refute result.key?('absent')
        end
      end

      it 'returns an empty hash when nothing is found' do
        memcached_persistent(p) do |dc|
          dc.flush

          assert_empty dc.get_multi_with_metadata(%w[none nothing])
        end
      end

      it 'returns an empty hash for no keys' do
        memcached_persistent(p) do |dc|
          assert_empty dc.get_multi_with_metadata([])
        end
      end

      # The distinction the whole method exists for: a tombstoned item is a hit
      # carrying stale: true, while a genuine miss is simply absent.
      it 'reports a tombstoned item as stale rather than missing' do
        memcached_persistent(p) do |_dc, port|
          dc = single_server_client(port)
          dc.flush
          dc.set('tomb', 'original')
          dc.set('fresh', 'untouched')
          tombstone(port, 'tomb')

          result = dc.get_multi_with_metadata(%w[tomb fresh absent])

          assert result['tomb'][:stale], 'tombstoned item should be stale'
          refute result['tomb'][:miss]
          refute result['fresh'][:stale]
          refute result.key?('absent'), 'a true miss is absent, not stale'
        end
      end

      it 'yields key and metadata when given a block' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('a', 'val_a')
          dc.set('b', 'val_b')

          collected = {}
          dc.get_multi_with_metadata(%w[a b absent]) { |k, meta| collected[k] = meta[:value] }

          assert_equal({ 'a' => 'val_a', 'b' => 'val_b' }, collected)
        end
      end

      it 'strips the namespace from returned keys' do
        memcached_persistent(p) do |_dc, port|
          dc = single_server_client(port, namespace: 'ns')
          dc.flush
          dc.set('a', 'val_a')

          result = dc.get_multi_with_metadata(%w[a absent])

          assert_equal ['a'], result.keys
          assert_equal 'val_a', result['a'][:value]
        end
      end

      it 'returns values unmarshalled in raw mode' do
        memcached_persistent(p) do |_dc, port|
          dc = single_server_client(port, raw: true)
          dc.flush
          dc.set('rk', 'raw_value')

          result = dc.get_multi_with_metadata(%w[rk absent])

          assert_equal 'raw_value', result['rk'][:value]
          assert_operator result['rk'][:cas], :positive?
        end
      end

      it 'handles keys requiring base64 encoding' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('contains space', 'space_val')
          dc.set('ƒ©åÍÎ', 'unicode_val')

          result = dc.get_multi_with_metadata(['contains space', 'ƒ©åÍÎ', 'missing'])

          assert_equal 'space_val', result['contains space'][:value]
          assert_equal 'unicode_val', result['ƒ©åÍÎ'][:value]
          refute result.key?('missing')
        end
      end

      it 'round-trips non-string values' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('num', 123)
          dc.set('arr', %w[a b c])

          result = dc.get_multi_with_metadata(%w[num arr])

          assert_equal 123, result['num'][:value]
          assert_equal %w[a b c], result['arr'][:value]
        end
      end
    end
  end
end
