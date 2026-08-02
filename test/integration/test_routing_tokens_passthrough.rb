# frozen_string_literal: true

require_relative '../helper'

# Integration tests for the opaque routing-token passthrough (`p_token` and
# `l_token`) on every public command. These tokens are encoded as the meta
# protocol's `P<token>` and `L<token>` flags. The vanilla memcached meta
# protocol does not assign any meaning to the letters `P` or `L`; vanilla
# memcached silently ignores them. They exist as a passthrough hook for
# proxies/routers in front of memcached.
#
# These tests assert three things:
#   1. Every command accepts the routing tokens without raising.
#   2. The operation completes successfully (the response is parsed cleanly
#      with the extra flags on the wire).
#   3. The presence of routing tokens DOES NOT change the return shape of
#      any command — that's the entire point of P/L being side-band metadata.
P_TOKEN = 'route=test-region'
L_TOKEN = 'hint=local'
ROUTING_OPTS = { p_token: P_TOKEN, l_token: L_TOKEN }.freeze

describe 'routing tokens (p_token / l_token) passthrough' do
  describe 'set / add / replace / set_cas' do
    it 'accepts routing tokens and stores the value, return shape unchanged' do
      memcached_persistent do |dc|
        dc.flush

        result = dc.set('rtk', 'val1', nil, ROUTING_OPTS)

        assert op_addset_succeeds(result)
        # set returns a CAS integer (or true) — never an Array
        refute_kind_of Array, result

        assert_equal 'val1', dc.get('rtk', ROUTING_OPTS)

        assert op_addset_succeeds(dc.replace('rtk', 'val2', nil, ROUTING_OPTS))
        assert_equal 'val2', dc.get('rtk')

        # add against an existing key still fails (without raising)
        refute dc.add('rtk', 'val3', nil, ROUTING_OPTS)

        dc.delete('rtk')

        assert op_addset_succeeds(dc.add('rtk', 'val4', nil, ROUTING_OPTS))
        assert_equal 'val4', dc.get('rtk')
      end
    end
  end

  describe 'get / gat' do
    it 'returns a scalar value (not a tuple) when routing tokens are passed' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        result = dc.get('rtk', ROUTING_OPTS)

        refute_kind_of Array, result
        assert_equal 'val', result

        # also exercise the with-only-p_token and with-only-l_token paths
        assert_equal 'val', dc.get('rtk', p_token: P_TOKEN)
        refute_kind_of Array, dc.get('rtk', p_token: P_TOKEN)

        assert_equal 'val', dc.get('rtk', l_token: L_TOKEN)
        refute_kind_of Array, dc.get('rtk', l_token: L_TOKEN)
      end
    end

    it 'returns nil on a miss (not a tuple) with routing tokens' do
      memcached_persistent do |dc|
        dc.flush

        assert_nil dc.get('absent', ROUTING_OPTS)
      end
    end

    it 'gat returns a scalar with routing tokens' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        result = dc.gat('rtk', 60, ROUTING_OPTS)

        refute_kind_of Array, result
        assert_equal 'val', result
      end
    end
  end

  describe 'delete' do
    it 'accepts routing tokens and deletes the value, return shape unchanged' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        assert dc.delete('rtk', ROUTING_OPTS)
        assert_nil dc.get('rtk')
      end
    end
  end

  describe 'incr / decr' do
    it 'accepts routing tokens and adjusts the counter, return shape unchanged' do
      memcached_persistent do |dc|
        dc.flush

        v = dc.incr('counter', 1, 60, 5, ROUTING_OPTS)

        assert_kind_of Integer, v
        assert_equal 5, v

        assert_equal 6, dc.incr('counter', 1, 60, 5, ROUTING_OPTS)
        assert_equal 4, dc.decr('counter', 2, 60, 5, ROUTING_OPTS)
      end
    end
  end

  describe 'append / prepend' do
    it 'accepts routing tokens and updates the value' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'middle', 0, raw: true)

        assert dc.append('rtk', '_end', ROUTING_OPTS)
        assert dc.prepend('rtk', 'start_', ROUTING_OPTS)

        assert_equal 'start_middle_end', dc.get('rtk', raw: true)
      end
    end
  end

  describe 'cas (optimistic locking)' do
    # Higher-order method: issues a meta-get for the read, then a meta-set for
    # the write. Both underlying commands must carry the routing tokens.
    it 'accepts routing tokens on both the read and write halves' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'orig')

        result = dc.cas('rtk', 60, ROUTING_OPTS) { |v| "#{v}-updated" }

        # Successful CAS returns truthy (CAS id), never a tuple-shape.
        assert result
        refute_kind_of Array, result
        assert_equal 'orig-updated', dc.get('rtk')
      end
    end

    it 'cas! also threads routing tokens' do
      memcached_persistent do |dc|
        dc.flush
        # cas! yields even when the key is missing
        dc.cas!('rtk', 60, ROUTING_OPTS) { |_v| 'created' }

        assert_equal 'created', dc.get('rtk')
      end
    end
  end

  describe 'get_cas' do
    it 'accepts routing tokens and returns [value, cas] (return shape unchanged)' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        result = dc.get_cas('rtk', ROUTING_OPTS)

        assert_kind_of Array, result
        assert_equal 2, result.length
        value, cas = result

        assert_equal 'val', value
        assert_kind_of Integer, cas
        refute_equal 0, cas
      end
    end

    it 'yields value and cas to the block when routing tokens are passed' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        yielded_value = nil
        yielded_cas = nil
        dc.get_cas('rtk', ROUTING_OPTS) do |v, c|
          yielded_value = v
          yielded_cas = c
        end

        assert_equal 'val', yielded_value
        assert_kind_of Integer, yielded_cas
      end
    end
  end

  describe 'get_multi' do
    it 'applies routing tokens to every key in the pipeline (single-server fast path)' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', '1')
        dc.set('b', '2')
        dc.set('c', '3')

        results = dc.get_multi('a', 'b', 'c', **ROUTING_OPTS)

        assert_kind_of Hash, results
        assert_equal({ 'a' => '1', 'b' => '2', 'c' => '3' }, results)
      end
    end

    it 'applies routing tokens in the block form' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', '1')
        dc.set('b', '2')

        seen = {}
        dc.get_multi('a', 'b', **ROUTING_OPTS) { |k, v| seen[k] = v }

        assert_equal({ 'a' => '1', 'b' => '2' }, seen)
      end
    end

    it 'works without routing tokens (backward-compat sanity)' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', '1')
        dc.set('b', '2')

        assert_equal({ 'a' => '1', 'b' => '2' }, dc.get_multi('a', 'b'))
      end
    end
  end

  describe 'get_multi_with_metadata' do
    it 'applies routing tokens to every key in the metadata-aware pipeline' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', '1')
        dc.set('b', '2')

        results = dc.get_multi_with_metadata('a', 'b', 'missing', **ROUTING_OPTS)

        assert_equal %w[a b missing], results.keys.sort
        assert_equal '1', results['a'][:value]
        assert_equal '2', results['b'][:value]
        assert results['missing'][:miss]
      end
    end
  end

  describe 'get_with_metadata' do
    it 'accepts routing tokens and returns the metadata hash' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rt-meta', 'v1')

        result = dc.get_with_metadata('rt-meta', **ROUTING_OPTS)

        assert_equal 'v1', result[:value]
        refute result[:miss]
        refute result[:stale]
        assert_operator result[:cas], :>, 0
      end
    end
  end

  describe 'set_multi (pipelined)' do
    it 'applies routing tokens to every entry in the pipeline' do
      memcached_persistent do |dc|
        dc.flush

        dc.set_multi({ 'a' => '1', 'b' => '2', 'c' => '3' }, 60, ROUTING_OPTS)

        assert_equal({ 'a' => '1', 'b' => '2', 'c' => '3' }, dc.get_multi('a', 'b', 'c'))
      end
    end
  end

  describe 'delete_multi (pipelined)' do
    it 'applies routing tokens to every entry in the pipeline' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('a', '1')
        dc.set('b', '2')
        dc.set('c', '3')

        deleted = dc.delete_multi(%w[a b c], ROUTING_OPTS)

        assert_equal 3, deleted
        assert_nil dc.get('a')
        assert_nil dc.get('b')
        assert_nil dc.get('c')
      end
    end
  end

  describe 'fetch (higher-order, regression coverage)' do
    # Previously discovered bug: when meta-protocol flags were stuffed into
    # `meta_flags`, `get` returned a `[value, flags_hash]` tuple, which broke
    # `fetch`'s miss-detection (`not_found?` saw a non-nil Array and treated
    # the miss as a hit, never invoking the block). Routing tokens must NOT
    # cause that — the `fetch` contract has to remain scalar-in / scalar-out.
    it 'returns the cached scalar value on hit when routing tokens are passed' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'cached')

        result = dc.fetch('rtk', 60, ROUTING_OPTS) { 'computed' }

        assert_equal 'cached', result
        refute_kind_of Array, result
      end
    end

    it 'invokes the block on a miss and caches the value when routing tokens are passed' do
      memcached_persistent do |dc|
        dc.flush

        block_invocations = 0
        result = dc.fetch('absent', 60, ROUTING_OPTS) do
          block_invocations += 1
          'computed'
        end

        assert_equal 1, block_invocations, 'fetch block must be invoked on a miss'
        assert_equal 'computed', result
        refute_kind_of Array, result

        # Confirm the value actually landed in the cache via the routing-token-bearing add.
        assert_equal 'computed', dc.get('absent')

        # Subsequent fetch should be a hit, no block invocation.
        result2 = dc.fetch('absent', 60, ROUTING_OPTS) do
          block_invocations += 1
          'should not run'
        end

        assert_equal 1, block_invocations, 'fetch block must not be invoked on a hit'
        assert_equal 'computed', result2
      end
    end

    it 'returns nil on a miss with no block, even when routing tokens are passed' do
      memcached_persistent do |dc|
        dc.flush

        assert_nil dc.fetch('absent', 60, ROUTING_OPTS)
      end
    end

    it 'works with cache_nils + routing tokens on a miss' do
      memcached_persistent(:meta, 21_345, '', cache_nils: true) do |dc|
        dc.flush

        invocations = 0
        result = dc.fetch('absent', 60, ROUTING_OPTS) do
          invocations += 1
          nil
        end

        assert_equal 1, invocations
        assert_nil result

        # Second fetch should hit the cached nil and NOT invoke the block.
        result2 = dc.fetch('absent', 60, ROUTING_OPTS) do
          invocations += 1
          'should not run'
        end

        assert_equal 1, invocations, 'cached nil should not trigger a re-fetch'
        assert_nil result2
      end
    end

    it 'works with cache_nils + routing tokens on a hit (non-nil cached value)' do
      memcached_persistent(:meta, 21_345, '', cache_nils: true) do |dc|
        dc.flush
        dc.set('rtk', 'cached')

        result = dc.fetch('rtk', 60, ROUTING_OPTS) { 'computed' }

        assert_equal 'cached', result
        refute_kind_of Array, result
      end
    end
  end

  describe 'wire-format hardening' do
    # `p_token` and `l_token` are appended verbatim to every meta-protocol
    # request line. Without sanitization, a value like `"foo\r\nflush_all\r\n"`
    # would be parsed as a second command by memcached or any intermediate
    # proxy/LB. The previous `meta_flags` API had the same hole; this PR is
    # the right moment to close it for the routing-token surface.
    it 'rejects p_token containing CR with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.set('safe_key', 'val', nil, p_token: "route=us\rinjected")
        end
      end
    end

    it 'rejects p_token containing LF with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.set('safe_key', 'val', nil, p_token: "route=us\nflush_all\n")
        end
      end
    end

    it 'rejects l_token containing CRLF with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.get('safe_key', l_token: "hint\r\nflush_all\r\n")
        end
      end
    end

    it 'rejects routing tokens containing null bytes with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.delete('safe_key', p_token: "route\0null")
        end
      end
    end

    it 'rejects non-String routing tokens with ArgumentError' do
      memcached_persistent do |dc|
        assert_raises(ArgumentError) do
          dc.set('safe_key', 'val', nil, p_token: 12_345)
        end
      end
    end

    it 'rejection happens before any wire write (state is not corrupted)' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('safe_key', 'original')

        assert_raises(ArgumentError) do
          dc.set('safe_key', 'should-not-store', nil, p_token: "x\r\ny")
        end

        # Subsequent operations on the same connection still work; the bad
        # set was rejected client-side, never reached the server.
        assert_equal 'original', dc.get('safe_key')
      end
    end

    it 'treats empty-string tokens as no-ops (no orphan P/L on the wire)' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val')

        # An orphan `P` or `L` with no value would either error at the proxy
        # or be silently misparsed. The client normalizes '' to nil so the
        # request is byte-identical to one with no routing tokens at all.
        assert_equal 'val', dc.get('rtk', p_token: '', l_token: '')
        assert op_addset_succeeds(dc.set('rtk2', 'v', nil, p_token: ''))
        assert_equal 'v', dc.get('rtk2')
        assert dc.delete('rtk2', l_token: '')
      end
    end
  end

  describe 'get_with_metadata (metadata + routing tokens together)' do
    # The old `meta_flags` escape hatch (which switched `get` to a
    # [value, flags_hash] tuple return) has been removed in favor of the
    # upstream-style `get_with_metadata` API: named request options in,
    # a stable metadata Hash out.
    it 'returns metadata and honors routing tokens on the same request' do
      memcached_persistent do |dc|
        dc.flush
        dc.set('rtk', 'val', 60)

        result = dc.get_with_metadata('rtk', return_hit_status: true, return_ttl_remaining: true,
                                             **ROUTING_OPTS)

        assert_equal 'val', result[:value]
        refute result[:miss]
        assert_operator result[:ttl_remaining], :>, 0
      end
    end

    it 'keeps get scalar-in/scalar-out: a stray meta_flags kwarg is quietly ignored' do
      # Unknown req_options keys flow into the options Hash where
      # Protocol::Meta does not look for them; the return shape stays scalar
      # and writes/deletes succeed normally.
      memcached_persistent do |dc|
        dc.flush

        assert op_addset_succeeds(dc.set('rtk', 'val', nil, meta_flags: ['s']))
        assert_equal 'val', dc.get('rtk', meta_flags: ['s'])
        assert dc.delete('rtk', meta_flags: ['s'])

        v = dc.incr('cnt', 1, 60, 5, meta_flags: ['s'])

        assert_kind_of Integer, v
      end
    end
  end
end
