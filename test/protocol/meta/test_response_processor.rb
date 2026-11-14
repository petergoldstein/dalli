# frozen_string_literal: true

require_relative '../../helper'

describe Dalli::Protocol::Meta::ResponseProcessor do
  let(:processor) { Dalli::Protocol::Meta::ResponseProcessor.new(nil, Dalli::Protocol::ValueMarshaller.new({})) }

  it 'rejects a buffered value with an invalid terminator' do
    ['VA 3 kfoo f0', 'VA 0 kfoo f0'].each do |header|
      body = header.start_with?('VA 0') ? 'XY' : 'abcXY'
      assert_raises(Dalli::DalliError) do
        processor.getk_response_from_buffer("#{header}\r\n#{body}")
      end
    end
  end

  it 'rejects an unterminated pipelined header over 8 KiB' do
    assert_raises(Dalli::DalliError) { processor.getk_response_from_buffer('X' * 8193) }
  end

  it 'rejects a claimed value larger than the configured response limit' do
    assert_raises(Dalli::DalliError) { processor.getk_response_from_buffer("VA 1048577 kfoo\r\n") }
  end

  it 'bounds complete stats replies' do
    processor.stub(:next_line_to_tokens, %w[STAT x y]) do
      assert_raises(Dalli::DalliError) { processor.stats }
    end
  end

  it 'bounds complete quiet replies' do
    processor.stub(:next_line_to_tokens, ['NF']) do
      assert_raises(Dalli::DalliError) { processor.consume_all_responses_until_mn(2) }
    end
  end

  describe '#getk_response_from_buffer' do
    # Malformed hits (a broken or hostile server or proxy): each must be
    # skipped or read whole, never yielded under a made-up key, taken for the
    # end of the pipeline, or allowed to leave bytes on the connection.
    it 'skips a hit with no key' do
      ["VA 1 f0 s1\r\nx\r\n", "VA 1 s1 b\r\nx\r\n", "VA 0 s0 b\r\n\r\n"].each do |reply|
        assert_equal [reply.bytesize, false, nil, nil, nil], processor.getk_response_from_buffer(reply.b), reply.inspect
      end
    end

    it 'reads a hit with no s flag using the size after VA' do
      reply = "VA 5 f0 kfoo\r\nhello\r\n"

      size, status, _cas, key, value = processor.getk_response_from_buffer("#{reply}MN\r\n".b)

      assert status
      assert_equal 'foo', key
      assert_equal 'hello', value
      assert_equal reply.bytesize, size
    end

    it 'rejects a pipelined reply that claims an impossible value size' do
      ["VA 4294967296 f0 kfoo s4294967296\r\n", "VA 4294967296 s4294967296 f0 kfoo\r\n"].each do |line|
        assert_raises(Dalli::DalliError) { processor.getk_response_from_buffer(line.b) }
      end
    end
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

      # The response buffer drops each parsed reply from the front
      rest = buf.byteslice(error.bytesize..)
      size, status, _cas, key, value = processor.getk_response_from_buffer(rest)

      assert status
      assert_equal 'foo', key
      assert_equal 'x', value
      assert_equal ["MN\r\n".bytesize, true, nil, nil, nil],
                   processor.getk_response_from_buffer(rest.byteslice(size..))
    end

    it 'skips SERVER_ERROR and EN replies the same way' do
      ["SERVER_ERROR out of memory storing object\r\n", "EN\r\n"].each do |line|
        assert_equal [line.bytesize, false, nil, nil, nil], processor.getk_response_from_buffer(line.b)
      end
    end
  end
end
