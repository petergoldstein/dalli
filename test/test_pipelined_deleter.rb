# frozen_string_literal: true

require_relative 'helper'

# See test/test_pipelined_getter.rb for the full explanation. Same bug,
# same fix, in the sibling class for delete_multi.
class FakeDeleterServer
  attr_reader :name, :call_count

  def initialize(&behavior)
    @name = 'fake:1'
    @call_count = 0
    @behavior = behavior
  end

  def request(*)
    @call_count += 1
    @behavior.call(@call_count, *)
  end
end

describe Dalli::PipelinedDeleter do
  let(:key_manager) { Dalli::KeyManager.new({}) }
  let(:deleter) { Dalli::PipelinedDeleter.new(nil, key_manager) }

  describe '#make_delete_requests' do
    it 'propagates a RetryableNetworkError instead of swallowing it' do
      server = FakeDeleterServer.new { raise Dalli::RetryableNetworkError, 'transient' }

      assert_raises(Dalli::RetryableNetworkError) do
        deleter.send(:make_delete_requests, { server => ['a'] })
      end
    end

    it 'propagates a plain NetworkError instead of swallowing it' do
      server = FakeDeleterServer.new { raise Dalli::NetworkError, 'connection reset' }

      assert_raises(Dalli::NetworkError) do
        deleter.send(:make_delete_requests, { server => ['a'] })
      end
    end

    it 'still swallows a non-network DalliError, moving on to the next server' do
      failing = FakeDeleterServer.new { raise Dalli::DalliError, 'server explicitly refused' }
      succeeding = FakeDeleterServer.new { |_n, *_args| nil }

      deleter.send(:make_delete_requests, { failing => ['a'], succeeding => ['b'] })

      assert_equal 1, failing.call_count
      assert_equal 1, succeeding.call_count
    end
  end

  describe '#finish_requests' do
    it 'propagates a RetryableNetworkError instead of swallowing it' do
      server = FakeDeleterServer.new { raise Dalli::RetryableNetworkError, 'transient' }

      assert_raises(Dalli::RetryableNetworkError) do
        deleter.send(:finish_requests, { server => ['a'] })
      end
    end
  end
end
