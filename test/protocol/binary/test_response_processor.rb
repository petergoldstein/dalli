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

  it 'rejects a large body before reading it' do
    source = Minitest::Mock.new
    source.expect :read, header(key_len: 0, extra_len: 0, body_len: 1_048_577), [24]
    parser = Dalli::Protocol::Binary::ResponseProcessor.new(source, Dalli::Protocol::ValueMarshaller.new({}))
    assert_raises(Dalli::DalliError) { parser.get }
    source.verify
  end

  it 'rejects a large authentication body before reading it' do
    assert_raises(Dalli::DalliError) do
      processor.auth_response(header(key_len: 0, extra_len: 0, body_len: 1_048_577))
    end
  end

  it 'rejects a large pipelined body' do
    assert_raises(Dalli::DalliError) do
      processor.getk_response_from_buffer(header(key_len: 0, extra_len: 0, body_len: 1_048_577))
    end
  end

  it 'rejects a body shorter than its declared key' do
    assert_raises(Dalli::DalliError) do
      processor.getk_response_from_buffer(header(key_len: 1, extra_len: 0, body_len: 0))
    end
  end

  it 'bounds complete stats replies' do
    response = Dalli::Protocol::Binary::ResponseHeader.new(header(key_len: 1, extra_len: 0, body_len: 1))

    processor.stub(:read_response, [response, 'x']) do
      assert_raises(Dalli::DalliError) { processor.stats }
    end
  end

  it 'bounds complete quiet replies' do
    response = Dalli::Protocol::Binary::ResponseHeader.new(header(key_len: 1, extra_len: 0, body_len: 1))

    processor.stub(:read_response, [response, 'x']) do
      assert_raises(Dalli::DalliError) { processor.consume_all_responses_until_noop(2) }
    end
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
