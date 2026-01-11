# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ConnectionManager do
  let(:hostname) { 'localhost' }
  let(:port) { 11_211 }
  let(:socket_type) { :tcp }
  let(:client_options) { {} }
  let(:connection_manager) { Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, client_options) }

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
