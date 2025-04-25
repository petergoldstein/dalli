# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ConnectionManager do
  let(:hostname) { 'localhost' }
  let(:port) { 11_211 }
  let(:socket_type) { :tcp }
  let(:client_options) { {} }
  let(:connection_manager) { Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, client_options) }

  describe '#close_on_fork' do
    it 'emits a deprecation warning' do
      logger_mock = Minitest::Mock.new
      expected_message = 'DEPRECATED: close_on_fork is deprecated and will be removed in a future version. ' \
                         'Use reconnect_on_fork instead.'
      logger_mock.expect(:warn, nil, [expected_message])
      logger_mock.expect(:info, nil) { true }

      Dalli.stub(:logger, logger_mock) do
        assert_raises(Dalli::NetworkError) do
          connection_manager.close_on_fork
        end
      end

      logger_mock.verify
    end

    it 'raises a NetworkError with the fork detection message' do
      with_nil_logger do
        error = assert_raises(Dalli::NetworkError) do
          connection_manager.close_on_fork
        end

        assert_equal 'Fork detected, re-connecting child process...', error.message
      end
    end

    it 'closes the socket' do
      socket_mock = Minitest::Mock.new
      socket_mock.expect(:close, nil)

      connection_manager.instance_variable_set(:@sock, socket_mock)

      with_nil_logger do
        assert_raises(Dalli::NetworkError) do
          connection_manager.close_on_fork
        end
      end

      socket_mock.verify

      assert_nil connection_manager.sock
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
end
