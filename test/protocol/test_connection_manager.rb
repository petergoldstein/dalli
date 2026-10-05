# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ConnectionManager do
  describe 'failure counting' do
    let(:manager) do
      Dalli::Protocol::ConnectionManager.new('localhost', 11_211, :tcp,
                                             { socket_max_failures: 2, socket_failure_delay: nil })
    end

    def fail_once(manager, message)
      with_nil_logger do
        assert_raises(Dalli::NetworkError) { manager.error_on_request!(message) }
      end
    end

    it 'keeps counting failures across a reconnect until a request succeeds' do
      fail_once(manager, 'first failure')

      assert_nil manager.instance_variable_get(:@down_at)

      manager.up! # a successful reconnect must not reset the count
      fail_once(manager, 'second failure')

      refute_nil manager.instance_variable_get(:@down_at), 'expected the server to be marked down'
    end

    it 'resets the count when a request completes' do
      fail_once(manager, 'first failure')
      manager.start_request!
      manager.finish_request!
      fail_once(manager, 'next failure')

      assert_nil manager.instance_variable_get(:@down_at)
    end
  end
end
