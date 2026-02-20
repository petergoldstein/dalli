# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Get' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'supports pipelined get' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          resp = dc.get_multi(%w[a b c d e f])

          assert_empty(resp)

          dc.set('a', 'foo')
          dc.set('b', 123)
          dc.set('c', %w[a b c])

          # Invocation without block
          resp = dc.get_multi(%w[a b c d e f])
          expected_resp = { 'a' => 'foo', 'b' => 123, 'c' => %w[a b c] }

          assert_equal(expected_resp, resp)

          # Invocation with block
          dc.get_multi(%w[a b c d e f]) do |k, v|
            assert(expected_resp.key?(k) && expected_resp[k] == v)
            expected_resp.delete(k)
          end

          assert_empty expected_resp

          # Perform a big quiet set with 1000 elements.
          arr = []
          dc.multi do
            1000.times do |idx|
              dc.set idx, idx
              arr << idx
            end
          end

          # Retrieve the elements with a pipelined get
          result = dc.get_multi(arr)

          assert_equal(1000, result.size)
          assert_equal(50, result['50'])
        end
      end

      it 'supports pipelined get with keys containing Unicode or spaces' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush

          keys_to_query = ['a', 'b', 'contains space', 'ƒ©åÍÎ']

          resp = dc.get_multi(keys_to_query)

          assert_empty(resp)

          dc.set('a', 'foo')
          dc.set('contains space', 123)
          dc.set('ƒ©åÍÎ', %w[a b c])

          # Invocation without block
          resp = dc.get_multi(keys_to_query)
          expected_resp = { 'a' => 'foo', 'contains space' => 123, 'ƒ©åÍÎ' => %w[a b c] }

          assert_equal(expected_resp, resp)

          # Invocation with block
          dc.get_multi(keys_to_query) do |k, v|
            assert(expected_resp.key?(k) && expected_resp[k] == v)
            expected_resp.delete(k)
          end

          assert_empty expected_resp
        end
      end

      describe 'pipeline_next_responses' do
        it 'raises NetworkError when called before pipeline_response_setup' do
          memcached_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            server.request(:pipelined_get, %w[a b])
            assert_raises Dalli::NetworkError do
              server.pipeline_next_responses
            end
          end
        end

        it 'raises NetworkError when called after pipeline_abort' do
          memcached_persistent(p) do |dc|
            server = dc.send(:ring).servers.first
            server.request(:pipelined_get, %w[a b])
            server.pipeline_response_setup
            server.pipeline_abort
            assert_raises Dalli::NetworkError do
              server.pipeline_next_responses
            end
          end
        end
      end

      describe 'single-server get_multi fast path' do
        it 'returns correct results via the fast path' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('a', 'foo')
            dc.set('b', 123)
            dc.set('c', %w[a b c])

            resp = dc.get_multi(%w[a b c d e f])
            expected = { 'a' => 'foo', 'b' => 123, 'c' => %w[a b c] }

            assert_equal(expected, resp)
          end
        end

        it 'returns correct results with raw mode' do
          memcached_persistent(p, 21_345, '', raw: true) do |dc|
            dc.flush

            dc.set('x', 'hello')
            dc.set('y', 'world')

            resp = dc.get_multi(%w[x y z])

            assert_equal({ 'x' => 'hello', 'y' => 'world' }, resp)
          end
        end

        it 'returns correct results with namespace' do
          memcached_persistent(p, 21_345, '', namespace: 'ns') do |dc|
            dc.flush

            dc.set('a', 'val_a')
            dc.set('b', 'val_b')

            resp = dc.get_multi(%w[a b c])

            assert_equal({ 'a' => 'val_a', 'b' => 'val_b' }, resp)
          end
        end

        it 'handles all misses' do
          memcached_persistent(p) do |dc|
            dc.flush

            resp = dc.get_multi(%w[miss1 miss2 miss3])

            assert_empty(resp)
          end
        end

        it 'handles Unicode and space keys via fast path' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('contains space', 'space_val')
            dc.set('ƒ©åÍÎ', 'unicode_val')

            resp = dc.get_multi(['contains space', 'ƒ©åÍÎ', 'missing'])

            assert_equal({ 'contains space' => 'space_val', 'ƒ©åÍÎ' => 'unicode_val' }, resp)
          end
        end

        it 'still uses block-based get_multi via PipelinedGetter' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('a', 'foo')
            dc.set('b', 'bar')

            collected = {}
            dc.get_multi(%w[a b c]) { |k, v| collected[k] = v }

            assert_equal({ 'a' => 'foo', 'b' => 'bar' }, collected)
          end
        end
      end

      describe 'pipelined_get_interleaved' do
        it 'works with chunked requests' do
          memcached_persistent(p) do |dc|
            dc.flush

            # Set some keys
            10.times { |i| dc.set("key#{i}", "value#{i}") }

            # Use get_multi with a lower interleave threshold to test the interleaved path
            # We'll temporarily modify the threshold constant
            original_threshold = Dalli::PipelinedGetter::INTERLEAVE_THRESHOLD
            original_chunk = Dalli::PipelinedGetter::CHUNK_SIZE
            begin
              Dalli::PipelinedGetter.send(:remove_const, :INTERLEAVE_THRESHOLD)
              Dalli::PipelinedGetter.send(:remove_const, :CHUNK_SIZE)
              Dalli::PipelinedGetter.const_set(:INTERLEAVE_THRESHOLD, 3)
              Dalli::PipelinedGetter.const_set(:CHUNK_SIZE, 3)

              # Now get_multi should use interleaved mode for 10 keys
              keys = Array.new(10) { |i| "key#{i}" }
              result = dc.get_multi(keys)

              # Verify we got all keys back
              assert_equal 10, result.size
              10.times do |i|
                assert_equal "value#{i}", result["key#{i}"]
              end
            ensure
              Dalli::PipelinedGetter.send(:remove_const, :INTERLEAVE_THRESHOLD)
              Dalli::PipelinedGetter.send(:remove_const, :CHUNK_SIZE)
              Dalli::PipelinedGetter.const_set(:INTERLEAVE_THRESHOLD, original_threshold)
              Dalli::PipelinedGetter.const_set(:CHUNK_SIZE, original_chunk)
            end
          end
        end
      end
    end
  end
end
