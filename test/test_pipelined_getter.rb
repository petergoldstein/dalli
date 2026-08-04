# frozen_string_literal: true

require_relative 'helper'

# A transient RetryableNetworkError from one server used to be swallowed by
# the same rescue clause that legitimately swallows a non-network DalliError
# (e.g. this server just doesn't have any of the requested keys), because
# NetworkError < DalliError and the two were caught together. That silently
# dropped the affected server's keys from the result instead of triggering
# #process's top-level retry -- the caller got back an incomplete Hash with
# no error and no indication anything went wrong.
class FakeGetterServer
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

describe Dalli::PipelinedGetter do
  let(:key_manager) { Dalli::KeyManager.new({}) }
  let(:getter) { Dalli::PipelinedGetter.new(nil, key_manager) }

  describe '#make_getkq_requests' do
    it 'propagates a RetryableNetworkError instead of swallowing it' do
      server = FakeGetterServer.new { raise Dalli::RetryableNetworkError, 'transient' }

      assert_raises(Dalli::RetryableNetworkError) do
        getter.send(:make_getkq_requests, { server => ['a'] })
      end
    end

    it 'propagates a plain NetworkError instead of swallowing it' do
      server = FakeGetterServer.new { raise Dalli::NetworkError, 'connection reset' }

      assert_raises(Dalli::NetworkError) do
        getter.send(:make_getkq_requests, { server => ['a'] })
      end
    end

    it 'still swallows a non-network DalliError, moving on to the next server' do
      failing = FakeGetterServer.new { raise Dalli::DalliError, 'server explicitly refused' }
      succeeding = FakeGetterServer.new { |_n, *_args| nil }

      getter.send(:make_getkq_requests, { failing => ['a'], succeeding => ['b'] })

      assert_equal 1, failing.call_count
      assert_equal 1, succeeding.call_count
    end
  end
end
