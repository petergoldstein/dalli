# frozen_string_literal: true

require_relative '../../helper'

describe Dalli::Protocol::Binary::ResponseProcessor do
  let(:processor) do
    Dalli::Protocol::Binary::ResponseProcessor.new(Object.new, Dalli::Protocol::ValueMarshaller.new({}))
  end

  # magic, opcode, key length, extras length, data type, status, body length,
  # opaque, CAS
  def header(key_len:, extra_len:, body_len:)
    [0x81, 0x00, key_len, extra_len, 0x00, 0, body_len, 0, 0].pack('CCnCCnNNQ')
  end

  describe '#getk_response_from_buffer' do
    it 'rejects a pipelined reply that claims an impossible body size' do
      buf = header(key_len: 3, extra_len: 4, body_len: 0xFFFF_FFFF)

      assert_raises(Dalli::DalliError) { processor.getk_response_from_buffer(buf) }
    end

    it 'still waits for the rest of a plausible reply' do
      buf = header(key_len: 3, extra_len: 4, body_len: 12)

      assert_equal [0, nil, nil, nil, nil], processor.getk_response_from_buffer(buf)
    end
  end
end
