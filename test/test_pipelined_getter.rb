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

  describe '#make_getkq_request' do
    it 'propagates a RetryableNetworkError instead of swallowing it' do
      server = FakeGetterServer.new { raise Dalli::RetryableNetworkError, 'transient' }

      assert_raises(Dalli::RetryableNetworkError) do
        getter.send(:make_getkq_request, server, ['a'])
      end
    end

    it 'propagates a plain NetworkError instead of swallowing it' do
      server = FakeGetterServer.new { raise Dalli::NetworkError, 'connection reset' }

      assert_raises(Dalli::NetworkError) do
        getter.send(:make_getkq_request, server, ['a'])
      end
    end

    it 'swallows a non-network DalliError' do
      failing = FakeGetterServer.new { raise Dalli::DalliError, 'server explicitly refused' }

      getter.send(:make_getkq_request, failing, ['a'])

      assert_equal 1, failing.call_count
    end
  end

  describe '#setup_requests' do
    # A fake server that records every call, in order, into a log shared by all servers
    def recording_server(name, log, fail_setup_with: nil)
      server = Object.new
      server.define_singleton_method(:name) { name }
      server.define_singleton_method(:connected?) { true }
      server.define_singleton_method(:request) { |opkey, *| log << [name, opkey] }
      server.define_singleton_method(:pipeline_abort) { log << [name, :abort] }
      server.define_singleton_method(:pipeline_response_setup) do
        log << [name, :setup]
        raise fail_setup_with if fail_setup_with
      end
      server
    end

    def run_setup(servers)
      groups = servers.to_h { |s| [s, ["#{s.name}-key"]] }
      getter.stub(:groups_for_keys, groups) { getter.send(:setup_requests, groups.values.flatten) }
    end

    it "sends each server's terminating noop before the next server's queries" do
      log = []
      servers = %w[s1 s2 s3].map { |n| recording_server(n, log) }

      assert_equal servers, run_setup(servers)
      assert_equal([%w[s1 pipelined_get], %w[s1 setup], %w[s2 pipelined_get], %w[s2 setup],
                    %w[s3 pipelined_get], %w[s3 setup]], log.map { |n, op| [n, op.to_s] })
    end

    it 'drops a server whose noop fails with a non-network DalliError' do
      log = []
      servers = [recording_server('s1', log, fail_setup_with: Dalli::DalliError),
                 recording_server('s2', log)]

      assert_equal [servers.last], run_setup(servers)
    end

    it 'aborts the servers already started, then re-raises, on a NetworkError' do
      log = []
      servers = [recording_server('s1', log),
                 recording_server('s2', log, fail_setup_with: Dalli::NetworkError),
                 recording_server('s3', log)]

      assert_raises(Dalli::NetworkError) { run_setup(servers) }
      assert_equal([%w[s1 abort], %w[s2 abort]], log.select { |_, op| op == :abort }.map { |n, op| [n, op.to_s] })
      refute(log.any? { |n, _| n == 's3' })
    end
  end
end
