# frozen_string_literal: true

require_relative '../../helper'

describe Dalli::Protocol::Meta::ResponseProcessor do
  let(:processor) { Dalli::Protocol::Meta::ResponseProcessor.new(nil, Dalli::Protocol::ValueMarshaller.new({})) }

  describe '#getk_response_from_buffer' do
    it 'returns an empty value for a VA 0 hit, consuming its terminator' do
      buf = +"VA 0 f0 kfoo s0\r\n\r\nMN\r\n"

      size, status, cas, key, value = processor.getk_response_from_buffer(buf)

      assert_equal "VA 0 f0 kfoo s0\r\n\r\n".bytesize, size
      assert status
      assert_equal 0, cas
      assert_equal 'foo', key
      assert_equal '', value
    end

    it 'waits for the terminator of a VA 0 hit' do
      assert_equal [0, nil, nil, nil, nil], processor.getk_response_from_buffer(+"VA 0 f0 kfoo s0\r\n")
    end

    it 'still treats MN as a reply with no body' do
      size, status, = processor.getk_response_from_buffer(+"MN\r\n")

      assert_equal 4, size
      assert status
    end
  end
end
