# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ConnectionManager do
  let(:hostname) { 'localhost' }
  let(:port) { 11_211 }
  let(:socket_type) { :tcp }
  let(:client_options) { {} }
  let(:connection_manager) { Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, client_options) }

  describe '#initialize' do
    it 'sets default options' do
      assert_equal 30, connection_manager.options[:down_retry_delay]
      assert_equal 1, connection_manager.options[:socket_timeout]
      assert_equal 2, connection_manager.options[:socket_max_failures]
      assert_in_delta(0.1, connection_manager.options[:socket_failure_delay])
      assert connection_manager.options[:keepalive]
    end

    it 'merges custom options with defaults' do
      custom_options = { socket_timeout: 5, down_retry_delay: 60 }
      cm = Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, custom_options)

      assert_equal 60, cm.options[:down_retry_delay]
      assert_equal 5, cm.options[:socket_timeout]
      assert_equal 2, cm.options[:socket_max_failures] # default preserved
    end
  end

  describe '#name' do
    it 'returns hostname:port for TCP sockets' do
      assert_equal 'localhost:11211', connection_manager.name
    end

    it 'returns just hostname for UNIX sockets' do
      cm = Dalli::Protocol::ConnectionManager.new('/tmp/memcached.sock', nil, :unix, {})

      assert_equal '/tmp/memcached.sock', cm.name
    end
  end

  describe '#connected?' do
    it 'returns false when socket is nil' do
      refute_predicate connection_manager, :connected?
    end

    it 'returns true when socket is present' do
      connection_manager.instance_variable_set(:@sock, Object.new)

      assert_predicate connection_manager, :connected?
    end
  end

  describe '#close' do
    it 'closes the socket and resets state' do
      socket_mock = Minitest::Mock.new
      socket_mock.expect(:close, nil)

      connection_manager.instance_variable_set(:@sock, socket_mock)
      connection_manager.instance_variable_set(:@pid, Process.pid)
      connection_manager.instance_variable_set(:@request_in_progress, true)

      connection_manager.close

      socket_mock.verify

      assert_nil connection_manager.sock
      refute_predicate connection_manager, :request_in_progress?
    end

    it 'handles socket close errors gracefully' do
      socket_mock = Object.new
      socket_mock.define_singleton_method(:close) { raise IOError, 'already closed' }

      connection_manager.instance_variable_set(:@sock, socket_mock)

      # Should not raise
      connection_manager.close

      assert_nil connection_manager.sock
    end

    it 'does nothing when socket is nil' do
      # Should not raise
      connection_manager.close

      assert_nil connection_manager.sock
    end
  end

  describe '#request_in_progress?' do
    it 'returns false initially' do
      refute_predicate connection_manager, :request_in_progress?
    end

    it 'returns true after start_request!' do
      connection_manager.start_request!

      assert_predicate connection_manager, :request_in_progress?
    end

    it 'returns false after finish_request!' do
      connection_manager.start_request!
      connection_manager.finish_request!

      refute_predicate connection_manager, :request_in_progress?
    end
  end

  describe '#start_request!' do
    it 'sets request_in_progress to true' do
      connection_manager.start_request!

      assert_predicate connection_manager, :request_in_progress?
    end

    it 'raises when request already in progress' do
      connection_manager.start_request!

      error = assert_raises(RuntimeError) do
        connection_manager.start_request!
      end

      assert_match(/Request already in progress/, error.message)
    end
  end

  describe '#finish_request!' do
    it 'sets request_in_progress to false' do
      connection_manager.start_request!
      connection_manager.finish_request!

      refute_predicate connection_manager, :request_in_progress?
    end

    it 'raises when no request in progress' do
      error = assert_raises(RuntimeError) do
        connection_manager.finish_request!
      end

      assert_match(/No request in progress/, error.message)
    end
  end

  describe '#abort_request!' do
    it 'sets request_in_progress to false without error' do
      connection_manager.start_request!
      connection_manager.abort_request!

      refute_predicate connection_manager, :request_in_progress?
    end

    it 'does not raise when no request in progress' do
      # Should not raise
      connection_manager.abort_request!

      refute_predicate connection_manager, :request_in_progress?
    end
  end

  describe '#reconnect_down_server?' do
    it 'returns true when server has never been down' do
      assert_predicate connection_manager, :reconnect_down_server?
    end

    it 'returns false when down_retry_delay has not passed' do
      connection_manager.instance_variable_set(:@last_down_at, Time.now)

      refute_predicate connection_manager, :reconnect_down_server?
    end

    it 'returns true when down_retry_delay has passed' do
      # Set down_retry_delay to 0 for test
      cm = Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, { down_retry_delay: 0 })
      cm.instance_variable_set(:@last_down_at, Time.now - 1)

      assert_predicate cm, :reconnect_down_server?
    end
  end

  describe '#reconnect_on_fork' do
    it 'establishes a new connection after closing the old one' do
      socket_mock = Minitest::Mock.new
      socket_mock.expect(:close, nil)

      new_socket = Object.new

      connection_manager.instance_variable_set(:@sock, socket_mock)
      connection_manager.define_singleton_method(:establish_connection) do
        @sock = new_socket
      end

      with_nil_logger do
        connection_manager.reconnect_on_fork
      end

      socket_mock.verify

      assert_equal new_socket, connection_manager.sock
    end
  end

  describe '#fork_detected?' do
    it 'returns false when pid is nil' do
      refute_predicate connection_manager, :fork_detected?
    end

    it 'returns false when pid matches current process' do
      connection_manager.instance_variable_set(:@pid, Dalli::PIDCache.pid)

      refute_predicate connection_manager, :fork_detected?
    end

    it 'returns true when pid differs from current process' do
      connection_manager.instance_variable_set(:@pid, -1) # Impossible PID

      assert_predicate connection_manager, :fork_detected?
    end
  end

  describe '#up!' do
    it 'resets down info' do
      connection_manager.instance_variable_set(:@fail_count, 5)
      connection_manager.instance_variable_set(:@down_at, Time.now)
      connection_manager.instance_variable_set(:@last_down_at, Time.now)

      with_nil_logger do
        connection_manager.up!
      end

      assert_equal 0, connection_manager.instance_variable_get(:@fail_count)
      assert_nil connection_manager.instance_variable_get(:@down_at)
      assert_nil connection_manager.instance_variable_get(:@last_down_at)
    end
  end

  describe '#error_on_request!' do
    it 'increments fail count' do
      initial_count = connection_manager.instance_variable_get(:@fail_count)

      with_nil_logger do
        assert_raises(Dalli::NetworkError) do
          connection_manager.error_on_request!('test error')
        end
      end

      assert_equal initial_count + 1, connection_manager.instance_variable_get(:@fail_count)
    end

    it 'marks server down after max failures' do
      cm = Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, { socket_max_failures: 1 })

      with_nil_logger do
        error = assert_raises(Dalli::NetworkError) do
          cm.error_on_request!('test error')
        end

        assert_match(/is down/, error.message)
      end
    end
  end
end
