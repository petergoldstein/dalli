# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::Base do
  describe 'raw_mode?' do
    it 'returns false when client is not in raw mode' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})

      refute_predicate server, :raw_mode?
    end

    it 'returns true when client is in raw mode' do
      server = Dalli::Protocol::Meta.new('localhost:11211', { raw: true })

      assert_predicate server, :raw_mode?
    end
  end

  describe 'alive?' do
    it 'returns true when the connection succeeds on the first attempt' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})

      server.stub(:ensure_connected!, -> { true }) do
        assert_predicate server, :alive?
      end
    end

    it 'retries once on a transient (retryable) network error and returns true if it then succeeds' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})
      attempts = 0
      flaky_connect = lambda do
        attempts += 1
        raise Dalli::RetryableNetworkError, 'transient blip' if attempts == 1

        true
      end

      server.stub(:ensure_connected!, flaky_connect) do
        assert_predicate server, :alive?
      end

      assert_equal 2, attempts
    end

    it 'returns false once a retryable failure is followed by a terminal network error' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})
      attempts = 0
      failing_connect = lambda do
        attempts += 1
        raise Dalli::RetryableNetworkError, 'transient blip' if attempts == 1

        raise Dalli::NetworkError, 'localhost:11211 is down'
      end

      server.stub(:ensure_connected!, failing_connect) do
        refute_predicate server, :alive?
      end

      assert_equal 2, attempts
    end

    it 'returns false immediately on a terminal network error, without retrying' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})
      attempts = 0
      failing_connect = lambda do
        attempts += 1
        raise Dalli::NetworkError, 'localhost:11211 is down'
      end

      server.stub(:ensure_connected!, failing_connect) do
        refute_predicate server, :alive?
      end

      assert_equal 1, attempts
    end
  end
end
