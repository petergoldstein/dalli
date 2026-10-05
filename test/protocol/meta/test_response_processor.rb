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

    it 'skips a bodyless error reply instead of treating it as the end of the pipeline' do
      error = "CLIENT_ERROR bad command line format\r\n"
      buf = "#{error}VA 1 f0 kfoo s1\r\nx\r\nMN\r\n".b

      assert_equal [error.bytesize, false, nil, nil, nil], processor.getk_response_from_buffer(buf)

      size, status, _cas, key, value = processor.getk_response_from_buffer(buf, error.bytesize)

      assert status
      assert_equal 'foo', key
      assert_equal 'x', value
      assert_equal ["MN\r\n".bytesize, true, nil, nil, nil],
                   processor.getk_response_from_buffer(buf, error.bytesize + size)
    end

    it 'skips SERVER_ERROR and EN replies the same way' do
      ["SERVER_ERROR out of memory storing object\r\n", "EN\r\n"].each do |line|
        assert_equal [line.bytesize, false, nil, nil, nil], processor.getk_response_from_buffer(line.b)
      end
    end
  end
end
