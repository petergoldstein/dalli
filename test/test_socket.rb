# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli::Socket::TCP' do
  describe '.supports_connect_timeout?' do
    before do
      # Clear the cached value before each test
      Dalli::Socket::TCP.remove_instance_variable(:@supports_connect_timeout) if
        Dalli::Socket::TCP.instance_variable_defined?(:@supports_connect_timeout)
    end

    def with_tcpsocket_parameters(params, &block)
      fake_method = Object.new
      fake_method.define_singleton_method(:parameters) { params }
      TCPSocket.stub(:instance_method, fake_method, &block)
    end

    it 'returns true for unmodified TCPSocket on MRI Ruby 3.0+' do
      skip 'Ruby 3.0+ required' if RUBY_VERSION < '3.0'
      skip 'MRI-specific test' if RUBY_ENGINE != 'ruby'

      # Assuming TCPSocket hasn't been monkey-patched in test environment
      # TruffleRuby and JRuby have different TCPSocket#initialize signatures
      assert_predicate Dalli::Socket::TCP, :supports_connect_timeout?
    end

    it 'returns false for Ruby < 3.0' do
      skip 'Only testable on Ruby < 3.0' if RUBY_VERSION >= '3.0'

      refute_predicate Dalli::Socket::TCP, :supports_connect_timeout?
    end

    it 'caches the result' do
      # First call
      result1 = Dalli::Socket::TCP.supports_connect_timeout?

      # Verify it's cached
      assert Dalli::Socket::TCP.instance_variable_defined?(:@supports_connect_timeout)

      # Second call should return same value
      result2 = Dalli::Socket::TCP.supports_connect_timeout?

      assert_equal result1, result2
    end

    it 'returns true for resolv-replace >= 0.2.0 which forwards keyword arguments' do
      skip 'Ruby 3.0+ required' if RUBY_VERSION < '3.0'
      skip 'MRI-specific test' if RUBY_ENGINE != 'ruby'

      # resolv-replace >= 0.2.0 uses def initialize(host, serv, *rest, **kwargs)
      params = [%i[req host], %i[req serv], %i[rest rest], %i[keyrest kwargs]]

      with_tcpsocket_parameters(params) do
        assert_predicate Dalli::Socket::TCP, :supports_connect_timeout?
      end
    end

    it 'returns false for resolv-replace < 0.2.0 which does not forward keyword arguments' do
      skip 'Ruby 3.0+ required' if RUBY_VERSION < '3.0'
      skip 'MRI-specific test' if RUBY_ENGINE != 'ruby'

      # resolv-replace < 0.2.0 uses def initialize(host, serv, *rest) - no kwargs
      params = [%i[req host], %i[req serv], %i[rest rest]]

      with_tcpsocket_parameters(params) do
        refute_predicate Dalli::Socket::TCP, :supports_connect_timeout?
      end
    end
  end

  describe '.create_socket_with_timeout' do
    it 'yields a socket when connection succeeds' do
      memcached(:meta, rand(21_500..21_600)) do |_, port|
        socket_yielded = false

        Dalli::Socket::TCP.create_socket_with_timeout('127.0.0.1', port, socket_timeout: 5) do |sock|
          socket_yielded = true

          assert_kind_of TCPSocket, sock
        end

        assert socket_yielded, 'Block should have been yielded to'
      end
    end

    it 'raises on connection timeout to non-existent server' do
      # Use a port that's unlikely to be listening
      assert_raises(Errno::ECONNREFUSED, Timeout::Error) do
        Dalli::Socket::TCP.create_socket_with_timeout('127.0.0.1', 59_999, socket_timeout: 1) do |_sock|
          flunk 'Should not yield socket for failed connection'
        end
      end
    end
  end
end
