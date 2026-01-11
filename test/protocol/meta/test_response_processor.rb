# frozen_string_literal: true

require_relative '../../helper'

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
    it 'returns [0, nil, nil, nil, nil] when buffer has no header' do
      buf = 'incomplete'
      result = processor.getk_response_from_buffer(buf)

      assert_equal [0, nil, nil, nil, nil], result
    end

    it 'returns header info for complete response without body' do
      buf = "MN\r\n"
      result = processor.getk_response_from_buffer(buf)

      assert_equal 4, result[0] # header length
      assert result[1] # ok status
    end
  end
end
