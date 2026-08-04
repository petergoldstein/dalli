# frozen_string_literal: true

require_relative 'helper'

# See test/test_pipelined_getter.rb for the full explanation. Same bug,
# same fix, in the sibling class for set_multi.
class FakeSetterServer
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

describe Dalli::PipelinedSetter do
  let(:key_manager) { Dalli::KeyManager.new({}) }
  let(:setter) { Dalli::PipelinedSetter.new(nil, key_manager) }

  describe '#make_set_requests' do
    it 'propagates a RetryableNetworkError instead of swallowing it' do
      server = FakeSetterServer.new { raise Dalli::RetryableNetworkError, 'transient' }

      assert_raises(Dalli::RetryableNetworkError) do
        setter.send(:make_set_requests, { server => ['a'] }, { 'a' => 'v' }, nil, nil)
      end
    end

    it 'propagates a plain NetworkError instead of swallowing it' do
      server = FakeSetterServer.new { raise Dalli::NetworkError, 'connection reset' }

      assert_raises(Dalli::NetworkError) do
        setter.send(:make_set_requests, { server => ['a'] }, { 'a' => 'v' }, nil, nil)
      end
    end

    it 'still swallows a non-network DalliError, moving on to the next server' do
      failing = FakeSetterServer.new { raise Dalli::DalliError, 'server explicitly refused' }
      succeeding = FakeSetterServer.new { |_n, *_args| nil }

      setter.send(:make_set_requests, { failing => ['a'], succeeding => ['b'] },
                  { 'a' => 'v1', 'b' => 'v2' }, nil, nil)

      assert_equal 1, failing.call_count
      assert_equal 1, succeeding.call_count
    end
  end

  describe '#finish_requests' do
    it 'propagates a RetryableNetworkError instead of swallowing it' do
      server = FakeSetterServer.new { raise Dalli::RetryableNetworkError, 'transient' }

      assert_raises(Dalli::RetryableNetworkError) do
        setter.send(:finish_requests, [server])
      end
    end
  end
end
