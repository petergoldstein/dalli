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

  describe 'response buffer' do
    def stale_buffer(server)
      buffer = server.send(:response_buffer)
      buffer.instance_variable_set(:@buffer, +"VA 5 kold\r\nstale\r\nMN\r\n")
      buffer
    end

    it 'starts pipelined_get_interleaved with an empty buffer' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})
      buffer = stale_buffer(server)
      seen = nil
      drain = ->(_results) { seen = buffer.instance_variable_get(:@buffer).dup }
      conn = server.instance_variable_get(:@connection_manager)

      server.stub(:write, lambda(&:bytesize)) do
        conn.stub(:flush, nil) do
          server.stub(:drain_pipeline_responses, drain) do
            server.send(:pipelined_get_interleaved, %w[a b], 10, {})
          end
        end
      end

      assert_equal '', seen
      assert_predicate buffer, :in_progress?
    end

    it 'is cleared when the connection closes' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})
      buffer = stale_buffer(server)
      conn = server.instance_variable_get(:@connection_manager)
      conn.instance_variable_set(:@sock, Minitest::Mock.new.expect(:close, nil))

      conn.close

      refute_predicate buffer, :in_progress?
    end
  end
end
