# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::Meta::ResponseProcessor do
  let(:io_source) { Minitest::Mock.new }
  let(:value_marshaller) { Dalli::Protocol::ValueMarshaller.new({}) }
  let(:processor) { Dalli::Protocol::Meta::ResponseProcessor.new(io_source, value_marshaller) }

  # Helper to simulate reading a line (with CRLF terminator)
  # Uses +'' to ensure the string is not frozen (chomp! needs mutable string)
  def expect_read_line(line)
    io_source.expect :read_line, "#{line}\r\n"
  end

  # Helper to simulate reading data (with CRLF terminator)
  # Uses +'' to ensure the string is not frozen (chomp! needs mutable string)
  def expect_read_data(data, size)
    io_source.expect :read, "#{data}\r\n", [size + 2]
  end

  describe 'negative value sizes' do
    # -1 and -2 plus the 2-byte terminator would read 1 or 0 bytes
    it 'rejects them before reading' do
      [-1, -2].each do |size|
        io_source.expect :read_line, "VA #{size} f0\r\n"

        assert_raises(Dalli::DalliError) { processor.meta_get_with_value }
      end
    end
  end

  describe '#meta_get_with_value' do
    describe 'when key is found (VA response)' do
      it 'returns the unmarshalled value' do
        test_value = 'hello world'
        serialized = Marshal.dump(test_value)

        expect_read_line("VA #{serialized.bytesize} f1")
        expect_read_data(serialized, serialized.bytesize)

        result = processor.meta_get_with_value

        assert_equal test_value, result
        io_source.verify
      end

      it 'reads the flags when they are not the first returned flag' do
        test_value = 'hello world'
        serialized = Marshal.dump(test_value)

        expect_read_line("VA #{serialized.bytesize} W f1 X")
        expect_read_data(serialized, serialized.bytesize)

        assert_equal test_value, processor.meta_get_with_value
        io_source.verify
      end

      it 'treats a missing flags token as flags 0 (raw mode)' do
        expect_read_line('VA 5')
        expect_read_data('hello', 5)

        assert_equal 'hello', processor.meta_get_with_value
        io_source.verify
      end
    end

    describe 'when the response is unexpected' do
      it 'raises ServerError on SERVER_ERROR' do
        expect_read_line('SERVER_ERROR out of memory')

        err = assert_raises(Dalli::ServerError) { processor.meta_get_with_value }
        assert_equal 'SERVER_ERROR out of memory', err.message
      end

      it 'raises DalliError on any other response' do
        expect_read_line('NS')

        err = assert_raises(Dalli::DalliError) { processor.meta_get_with_value }
        assert_equal 'Response error: NS', err.message
      end
    end

    describe 'when key is not found (EN response)' do
      it 'returns nil by default' do
        expect_read_line('EN')

        result = processor.meta_get_with_value

        assert_nil result
        io_source.verify
      end

      it 'returns NOT_FOUND sentinel when cache_nils is true' do
        expect_read_line('EN')

        result = processor.meta_get_with_value(cache_nils: true)

        assert_equal Dalli::NOT_FOUND, result
        io_source.verify
      end
    end

    describe 'when HD response (touch success)' do
      it 'returns true' do
        expect_read_line('HD')

        result = processor.meta_get_with_value

        assert result
        io_source.verify
      end
    end
  end

  describe '#meta_get_with_value_and_cas' do
    it 'returns [value, cas] tuple on success' do
      test_value = { key: 'value' }
      serialized = Marshal.dump(test_value)
      cas_value = 12_345

      expect_read_line("VA #{serialized.bytesize} f1 c#{cas_value}")
      expect_read_data(serialized, serialized.bytesize)

      value, cas = processor.meta_get_with_value_and_cas

      assert_equal test_value, value
      assert_equal cas_value, cas
      io_source.verify
    end

    it 'returns [nil, 0] on EN response' do
      expect_read_line('EN')

      value, cas = processor.meta_get_with_value_and_cas

      assert_nil value
      assert_equal 0, cas
      io_source.verify
    end
  end

  describe '#meta_get_without_value' do
    it 'returns true on HD response' do
      expect_read_line('HD')

      result = processor.meta_get_without_value

      assert result
      io_source.verify
    end

    it 'returns nil on EN response' do
      expect_read_line('EN')

      result = processor.meta_get_without_value

      assert_nil result
      io_source.verify
    end
  end

  describe '#meta_set_with_cas' do
    it 'reads the CAS when it is the first flag' do
      expect_read_line('HD c7')

      assert_equal 7, processor.meta_set_with_cas
      io_source.verify
    end

    it 'reads the CAS when other flags come first' do
      expect_read_line('HD b c42')

      assert_equal 42, processor.meta_set_with_cas
      io_source.verify
    end

    it 'returns 0 for an HD response without a CAS' do
      expect_read_line('HD')

      assert_equal 0, processor.meta_set_with_cas
      io_source.verify
    end

    it 'raises ServerError on SERVER_ERROR' do
      expect_read_line('SERVER_ERROR out of memory')

      assert_raises(Dalli::ServerError) { processor.meta_set_with_cas }
    end

    it 'raises DalliError on an unexpected response' do
      expect_read_line('EN')

      err = assert_raises(Dalli::DalliError) { processor.meta_set_with_cas }
      assert_equal 'Response error: EN', err.message
    end

    it 'returns CAS value on HD response' do
      cas_value = 98_765
      expect_read_line("HD c#{cas_value}")

      result = processor.meta_set_with_cas

      assert_equal cas_value, result
      io_source.verify
    end

    it 'returns false on NS response' do
      expect_read_line('NS')

      result = processor.meta_set_with_cas

      refute result
      io_source.verify
    end

    it 'returns false on NF response' do
      expect_read_line('NF')

      result = processor.meta_set_with_cas

      refute result
      io_source.verify
    end

    it 'returns false on EX response (CAS mismatch)' do
      expect_read_line('EX')

      result = processor.meta_set_with_cas

      refute result
      io_source.verify
    end
  end

  describe '#meta_set_append_prepend' do
    it 'returns true on HD response' do
      expect_read_line('HD')

      result = processor.meta_set_append_prepend

      assert result
      io_source.verify
    end

    it 'returns false on NS response' do
      expect_read_line('NS')

      result = processor.meta_set_append_prepend

      refute result
      io_source.verify
    end
  end

  describe '#meta_delete' do
    it 'returns false on EX (CAS mismatch)' do
      expect_read_line('EX')

      refute processor.meta_delete
      io_source.verify
    end

    it 'raises DalliError on an unexpected response' do
      expect_read_line('NS')

      err = assert_raises(Dalli::DalliError) { processor.meta_delete }
      assert_equal 'Response error: NS', err.message
    end

    it 'returns true on HD response' do
      expect_read_line('HD')

      result = processor.meta_delete

      assert result
      io_source.verify
    end

    it 'returns false on NF response' do
      expect_read_line('NF')

      result = processor.meta_delete

      refute result
      io_source.verify
    end
  end

  describe '#decr_incr' do
    it 'parses VA response with numeric value' do
      expect_read_line('VA 2')
      io_source.expect :read_line, +"42\r\n"

      result = processor.decr_incr

      assert_equal 42, result
      io_source.verify
    end

    it 'returns nil on NF response' do
      expect_read_line('NF')

      result = processor.decr_incr

      assert_nil result
      io_source.verify
    end

    it 'returns false on NS response' do
      expect_read_line('NS')

      result = processor.decr_incr

      refute result
      io_source.verify
    end

    it 'returns false on EX response' do
      expect_read_line('EX')

      result = processor.decr_incr

      refute result
      io_source.verify
    end
  end

  describe '#stats' do
    it 'parses stat key-value pairs' do
      expect_read_line('STAT pid 12345')
      expect_read_line('STAT uptime 3600')
      expect_read_line('END')

      result = processor.stats

      assert_equal({ 'pid' => '12345', 'uptime' => '3600' }, result)
      io_source.verify
    end

    it 'handles empty stats response' do
      expect_read_line('END')

      result = processor.stats

      assert_empty(result)
      io_source.verify
    end
  end

  describe '#version' do
    it 'returns version string' do
      expect_read_line('VERSION 1.6.22')

      result = processor.version

      assert_equal '1.6.22', result
      io_source.verify
    end
  end

  describe '#flush' do
    it 'returns true on OK response' do
      expect_read_line('OK')

      result = processor.flush

      assert result
      io_source.verify
    end
  end

  describe '#reset' do
    it 'returns true on RESET response' do
      expect_read_line('RESET')

      result = processor.reset

      assert result
      io_source.verify
    end
  end

  describe '#consume_all_responses_until_mn' do
    it 'reads and discards responses until MN' do
      expect_read_line('HD c123')
      expect_read_line('NS')
      expect_read_line('MN')

      result = processor.consume_all_responses_until_mn

      assert result
      io_source.verify
    end
  end

  describe '#pipelined_delete_non_deletions' do
    it 'returns 0 when every delete succeeded (all responses suppressed)' do
      expect_read_line('MN')

      assert_equal 0, processor.pipelined_delete_non_deletions
      io_source.verify
    end

    it 'counts NF misses' do
      expect_read_line('NF')
      expect_read_line('NF')
      expect_read_line('MN')

      assert_equal 2, processor.pipelined_delete_non_deletions
      io_source.verify
    end

    it 'counts error responses as non-deletions, not just NF misses' do
      expect_read_line('NF')
      expect_read_line('CLIENT_ERROR bad command line format')
      expect_read_line('MN')

      assert_equal 2, processor.pipelined_delete_non_deletions
      io_source.verify
    end
  end

  describe 'error handling' do
    it 'raises DalliError for unexpected response' do
      expect_read_line('UNEXPECTED')

      err = assert_raises(Dalli::DalliError) do
        processor.meta_get_with_value
      end
      assert_includes err.message, 'UNEXPECTED'
      io_source.verify
    end

    it 'raises ServerError for SERVER_ERROR response' do
      expect_read_line('SERVER_ERROR out of memory')

      err = assert_raises(Dalli::ServerError) do
        processor.meta_get_with_value
      end
      assert_includes err.message, 'out of memory'
      io_source.verify
    end
  end

  describe '#getk_response_from_buffer' do
    # Malformed hits (a broken or hostile server or proxy): each must be
    # skipped or read whole, never yielded under a made-up key, taken for the
    # end of the pipeline, or allowed to leave bytes on the connection.
    it 'skips a hit with no key, on both parse paths' do
      ["VA 1 f0 s1\r\nx\r\n", "VA 1 s1 b\r\nx\r\n", "VA 0 s0 b\r\n\r\n"].each do |reply|
        assert_equal [false, reply.bytesize], processor.getk_response_from_buffer(reply.b), reply.inspect
      end
    end

    it 'reads a hit with no s flag using the size after VA' do
      reply = "VA 5 f0 kfoo\r\nhello\r\n"

      status, _cas, key, value, size = processor.getk_response_from_buffer("#{reply}MN\r\n".b)

      assert status
      assert_equal 'foo', key
      assert_equal 'hello', value
      assert_equal reply.bytesize, size
    end

    it 'reads flags in any order, a base64 key, and a missing CAS' do
      value = Marshal.dump('hello')
      key = ['key with spaces'].pack('m0')
      buf = "VA #{value.bytesize} s#{value.bytesize} k#{key} W b f1\r\n#{value}\r\n".b

      status, cas, returned_key, returned_value, size = processor.getk_response_from_buffer(buf)

      assert status
      assert_equal 0, cas
      assert_equal 'key with spaces', returned_key
      assert_equal 'hello', returned_value
      assert_equal buf.bytesize, size
    end

    it 'returns an empty value for a VA 0 hit, consuming its terminator' do
      buf = "VA 0 f0 kfoo s0\r\n\r\nMN\r\n".b

      status, cas, key, value, size = processor.getk_response_from_buffer(buf)

      assert status
      assert_equal 0, cas
      assert_equal 'foo', key
      assert_equal '', value
      assert_equal "VA 0 f0 kfoo s0\r\n\r\n".bytesize, size
    end

    it 'returns [0] for a VA 0 hit whose terminator has not arrived' do
      assert_equal [0], processor.getk_response_from_buffer("VA 0 f0 kfoo s0\r\n".b)
    end

    it 'parses VA headers in place with the same results as the token path' do
      tokens_only = Dalli::Protocol::Meta::ResponseProcessor.new(io_source, value_marshaller)
      tokens_only.define_singleton_method(:va_response_from_buffer) { |*| nil }
      value = Marshal.dump('hello')
      b64 = ['k€y'].pack('m0')
      headers = [
        "VA #{value.bytesize} f1 kfoo s#{value.bytesize}\r\n#{value}\r\n",
        "VA #{value.bytesize} f1 c42 kfoo s#{value.bytesize}\r\n#{value}\r\n",
        "VA 5 f4 kbar s5\r\nhello\r\n",
        "VA 5 s5 f0 kbar\r\nhello\r\n",
        "VA 5 f0 k#{b64} b s5\r\nhello\r\n",
        "VA 5 b f0 k#{b64} s5\r\nhello\r\n",
        "VA 5 f0 kbar s5 f7 c1 c2 kother\r\nhello\r\n",
        "VA 5 kbar s5\r\nhello\r\n",
        "VA 5 f0 s5\r\nhello\r\n",
        "VA 5 f0 kbar s5 bx W Z\r\nhello\r\n",
        "VA 5 f4x kbar s5\r\nhello\r\n",
        "VA 5 f0 kbar s5\r\nhel",
        'VA 5 f0 kbar s5',
        "VA 0 f0 kbar s0\r\n\r\n",
        "VA 5 f0 kbar\r\nhello\r\n"
      ]

      headers.each do |response|
        # A non-zero offset, as when earlier responses are still in the buffer
        buf = "HD\r\n#{response}MN\r\n".b

        assert_equal tokens_only.getk_response_from_buffer(buf.dup, 4),
                     processor.getk_response_from_buffer(buf.dup, 4), response.inspect
      end
      # and the in-place parse is what handles a normal hit
      hit = headers.first.b

      assert_equal 'hello', processor.send(:va_response_from_buffer, hit, 0, hit.index("\r\n"))[3]
    end

    it 'reads the key from a VA line' do
      b64 = ['k€y'].pack('m0')

      assert_equal 'foo', processor.key_from_va_line("VA 5 f0 kfoo s5\r\n")
      assert_equal 'foo', processor.key_from_va_line("VA 5 kfoo s5\r\n")
      assert_equal 'foo', processor.key_from_va_line("VA 5 f0 kfoo\r\n")
      assert_equal 'b', processor.key_from_va_line("VA 5 f0 kb s5\r\n")
      assert_equal 'k€y', processor.key_from_va_line("VA 5 f0 k#{b64} b s5\r\n").force_encoding(Encoding::UTF_8)
      assert_equal 'k€y', processor.key_from_va_line("VA 5 f0 k#{b64} s5 b\r\n").force_encoding(Encoding::UTF_8)
      assert_nil processor.key_from_va_line("VA 5 f0 s5\r\n")
    end

    it 'rejects a pipelined reply that claims an impossible value size' do
      ["VA 4294967296 f0 kfoo s4294967296\r\n", "VA 4294967296 s4294967296 f0 kfoo\r\n"].each do |line|
        assert_raises(Dalli::DalliError) { processor.getk_response_from_buffer(line.b) }
      end
    end

    it 'skips a bodyless error reply instead of treating it as the end of the pipeline' do
      error = "CLIENT_ERROR bad command line format\r\n"
      buf = "#{error}VA 1 f0 kfoo s1\r\nx\r\nMN\r\n".b

      assert_equal [false, error.bytesize], processor.getk_response_from_buffer(buf)

      status, _cas, key, value, size = processor.getk_response_from_buffer(buf, error.bytesize)

      assert status
      assert_equal 'foo', key
      assert_equal 'x', value
      assert_equal [true, "MN\r\n".bytesize], processor.getk_response_from_buffer(buf, error.bytesize + size)
    end

    it 'skips SERVER_ERROR and EN replies the same way' do
      ["SERVER_ERROR out of memory storing object\r\n", "EN\r\n"].each do |line|
        assert_equal [false, line.bytesize], processor.getk_response_from_buffer(line.b)
      end
    end

    it 'returns [0] when the body has not fully arrived' do
      buf = "VA 5 f0 c1 kfoo s5\r\nhel".b

      assert_equal [0], processor.getk_response_from_buffer(buf)
    end

    it 'returns [0, nil, nil, nil, nil] when buffer has no header' do
      buf = 'incomplete'
      result = processor.getk_response_from_buffer(buf)

      assert_equal [0], result
    end

    it 'returns header info for complete response without body' do
      buf = "MN\r\n"
      result = processor.getk_response_from_buffer(buf)

      assert_equal 4, result.last # header length
      assert result[0] # ok status
    end
  end
  describe '#meta_get_with_metadata' do
    it 'marks an EN response as a miss' do
      expect_read_line('EN')

      result = processor.meta_get_with_metadata

      assert result[:miss]
      assert_nil result[:value]
      io_source.verify
    end

    it 'does not mark a found item as a miss' do
      serialized = Marshal.dump('hello')
      expect_read_line("VA #{serialized.bytesize} f1 c7")
      expect_read_data(serialized, serialized.bytesize)

      result = processor.meta_get_with_metadata

      refute result[:miss]
      assert_equal 'hello', result[:value]
      assert_equal 7, result[:cas]
      io_source.verify
    end

    # A tombstoned item answers VA with the X flag, so it must not be reported as
    # a miss -- that distinction is the whole point of the :miss key.
    it 'does not mark a stale item as a miss' do
      serialized = Marshal.dump('stale value')
      expect_read_line("VA #{serialized.bytesize} f1 X")
      expect_read_data(serialized, serialized.bytesize)

      result = processor.meta_get_with_metadata

      refute result[:miss]
      assert result[:stale]
      io_source.verify
    end

    it 'omits ttl_remaining unless requested' do
      serialized = Marshal.dump('v')
      expect_read_line("VA #{serialized.bytesize} f1 t42")
      expect_read_data(serialized, serialized.bytesize)

      result = processor.meta_get_with_metadata

      refute result.key?(:ttl_remaining)
      io_source.verify
    end

    it 'returns ttl_remaining when requested' do
      serialized = Marshal.dump('v')
      expect_read_line("VA #{serialized.bytesize} f1 t42")
      expect_read_data(serialized, serialized.bytesize)

      result = processor.meta_get_with_metadata(return_ttl_remaining: true)

      assert_equal 42, result[:ttl_remaining]
      io_source.verify
    end

    it 'returns -1 for ttl_remaining when the item has no expiry' do
      serialized = Marshal.dump('v')
      expect_read_line("VA #{serialized.bytesize} f1 t-1")
      expect_read_data(serialized, serialized.bytesize)

      result = processor.meta_get_with_metadata(return_ttl_remaining: true)

      assert_equal(-1, result[:ttl_remaining])
      io_source.verify
    end
  end
end
