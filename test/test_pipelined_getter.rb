# frozen_string_literal: true

require_relative 'helper'

describe Dalli::PipelinedGetter do
  it 'waits when no decrypted TLS bytes are pending' do
    socket = Object.new
    socket.define_singleton_method(:buffered_data?) { true }
    socket.define_singleton_method(:pending_data?) { false }
    server = Struct.new(:sock).new(socket)
    getter = Dalli::PipelinedGetter.new(nil, nil)

    IO.stub(:select, nil) do
      assert_empty getter.send(:servers_with_response, [server], 0.01)
    end
  end
end
