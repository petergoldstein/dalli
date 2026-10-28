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

  [Dalli::Protocol::Binary, Dalli::Protocol::Meta].each do |protocol_class|
    describe "response buffer (#{protocol_class.name.split('::').last})" do
      def stale_buffer(server)
        buffer = server.send(:response_buffer)
        buffer.instance_variable_set(:@buffer, +"VA 5 kold\r\nstale\r\nMN\r\n")
        buffer
      end

      it 'starts pipelined_get_interleaved with an empty buffer' do
        server = protocol_class.new('localhost:11211', {})
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
        server = protocol_class.new('localhost:11211', {})
        buffer = stale_buffer(server)
        conn = server.instance_variable_get(:@connection_manager)
        conn.instance_variable_set(:@sock, Minitest::Mock.new.expect(:close, nil))

        conn.close

        refute_predicate buffer, :in_progress?
      end
    end
  end
end
