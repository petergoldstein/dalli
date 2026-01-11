# frozen_string_literal: true

require_relative '../../helper'

describe Dalli::Protocol::Binary::ResponseProcessor do
  # Helper to create a binary response header
  # Format: magic(1) + opcode(1) + key_len(2) + extra_len(1) + data_type(1) +
  #         status(2) + body_len(4) + opaque(4) + cas(8)
  # Note: CAS uses native endian (Q) to match ResponseHeader's FMT = '@2nCCnNNQ'
  # rubocop:disable Metrics/ParameterLists
  def create_header(status: 0, key_len: 0, extra_len: 0, body_len: 0, cas: 0, opaque: 0)
    [
      0x81,        # magic (response)
      0x00,        # opcode
      key_len,     # key length (big-endian)
      extra_len,   # extra length
      0x00,        # data type
      status,      # status (big-endian)
      body_len,    # total body length (big-endian)
      opaque,      # opaque (big-endian)
      cas          # CAS (native endian)
    ].pack('CCnCCnNNQ')
  end
  # rubocop:enable Metrics/ParameterLists

  let(:io_source) { Minitest::Mock.new }
  let(:value_marshaller) { Dalli::Protocol::ValueMarshaller.new({}) }
  let(:processor) { Dalli::Protocol::Binary::ResponseProcessor.new(io_source, value_marshaller) }

  describe '#get' do
    describe 'when key is found' do
      it 'returns the unmarshalled value' do
        test_value = 'test_value'
        serialized = Marshal.dump(test_value)
        body = [0x01].pack('N') + serialized # bitflags (FLAG_SERIALIZED) + value
        header = create_header(status: 0, extra_len: 4, body_len: body.bytesize, cas: 12_345)

        io_source.expect :read, header, [24]
        io_source.expect :read, body, [body.bytesize]

        result = processor.get

        assert_equal test_value, result
        io_source.verify
      end
    end

    describe 'when key is not found' do
      it 'returns nil by default' do
        header = create_header(status: 1)  # NOT_FOUND status

        io_source.expect :read, header, [24]

        result = processor.get

        assert_nil result
        io_source.verify
      end

      it 'returns NOT_FOUND sentinel when cache_nils is true' do
        header = create_header(status: 1)  # NOT_FOUND status

        io_source.expect :read, header, [24]

        result = processor.get(cache_nils: true)

        assert_equal Dalli::NOT_FOUND, result
        io_source.verify
      end
    end

    describe 'when not stored' do
      it 'returns false' do
        header = create_header(status: 5)  # NOT_STORED status

        io_source.expect :read, header, [24]

        result = processor.get

        refute result
        io_source.verify
      end
    end
  end

  describe '#storage_response' do
    it 'returns CAS value on success' do
      cas_value = 98_765
      header = create_header(status: 0, cas: cas_value)

      io_source.expect :read, header, [24]

      result = processor.storage_response

      assert_equal cas_value, result
      io_source.verify
    end

    it 'returns false on KEY_EXISTS (status 2)' do
      header = create_header(status: 2)

      io_source.expect :read, header, [24]

      result = processor.storage_response

      refute result
      io_source.verify
    end

    it 'returns nil on KEY_NOT_FOUND (status 1)' do
      header = create_header(status: 1)

      io_source.expect :read, header, [24]

      result = processor.storage_response

      assert_nil result
      io_source.verify
    end

    it 'returns false on NOT_STORED (status 5)' do
      header = create_header(status: 5)

      io_source.expect :read, header, [24]

      result = processor.storage_response

      refute result
      io_source.verify
    end
  end

  describe '#delete' do
    it 'returns true on success' do
      header = create_header(status: 0)

      io_source.expect :read, header, [24]

      result = processor.delete

      assert result
      io_source.verify
    end

    it 'returns false on KEY_NOT_FOUND' do
      header = create_header(status: 1)

      io_source.expect :read, header, [24]

      result = processor.delete

      refute result
      io_source.verify
    end

    it 'returns false on NOT_STORED' do
      header = create_header(status: 5)

      io_source.expect :read, header, [24]

      result = processor.delete

      refute result
      io_source.verify
    end
  end

  describe '#decr_incr' do
    it 'returns numeric value on success' do
      counter_value = 42
      body = [counter_value].pack('Q>')
      header = create_header(status: 0, body_len: 8)

      io_source.expect :read, header, [24]
      io_source.expect :read, body, [8]

      result = processor.decr_incr

      assert_equal counter_value, result
      io_source.verify
    end

    it 'returns nil on KEY_NOT_FOUND' do
      header = create_header(status: 1)

      io_source.expect :read, header, [24]

      result = processor.decr_incr

      assert_nil result
      io_source.verify
    end
  end

  describe '#version' do
    it 'returns version string' do
      version_str = '1.6.22'
      header = create_header(status: 0, body_len: version_str.bytesize)

      io_source.expect :read, header, [24]
      io_source.expect :read, version_str, [version_str.bytesize]

      result = processor.version

      assert_equal version_str, result
      io_source.verify
    end
  end

  describe '#data_cas_response' do
    it 'returns [value, cas] tuple on success' do
      test_value = { foo: 'bar' }
      serialized = Marshal.dump(test_value)
      body = [0x01].pack('N') + serialized # bitflags + value
      cas_value = 54_321
      header = create_header(status: 0, extra_len: 4, body_len: body.bytesize, cas: cas_value)

      io_source.expect :read, header, [24]
      io_source.expect :read, body, [body.bytesize]

      value, cas = processor.data_cas_response

      assert_equal test_value, value
      assert_equal cas_value, cas
      io_source.verify
    end

    it 'returns [nil, cas] on KEY_NOT_FOUND' do
      cas_value = 0
      header = create_header(status: 1, cas: cas_value)

      io_source.expect :read, header, [24]

      value, cas = processor.data_cas_response

      assert_nil value
      assert_equal cas_value, cas
      io_source.verify
    end
  end

  describe '#no_body_response' do
    it 'returns true on success' do
      header = create_header(status: 0)

      io_source.expect :read, header, [24]

      result = processor.no_body_response

      assert result
      io_source.verify
    end

    it 'returns false on NOT_STORED' do
      header = create_header(status: 5)

      io_source.expect :read, header, [24]

      result = processor.no_body_response

      refute result
      io_source.verify
    end
  end

  describe '#getk_response_from_buffer' do
    it 'returns [0, nil, nil, nil, nil] when buffer is too small for header' do
      small_buf = 'x' * 10
      result = processor.getk_response_from_buffer(small_buf)

      assert_equal [0, nil, nil, nil, nil], result
    end

    it 'returns [header_size, true, cas, nil, nil] for noop response (ok status, no body)' do
      header = create_header(status: 0, cas: 12_345)
      result = processor.getk_response_from_buffer(header)

      assert_equal [24, true, 12_345, nil, nil], result
    end

    it 'returns [header_size, false, cas, nil, nil] for error response (non-ok status, no body)' do
      header = create_header(status: 1, cas: 0) # NOT_FOUND
      result = processor.getk_response_from_buffer(header)

      assert_equal [24, false, 0, nil, nil], result
    end

    it 'returns [0, nil, nil, nil, nil] when body is incomplete' do
      # Header says body is 100 bytes, but we only have header
      header = create_header(status: 0, body_len: 100)
      result = processor.getk_response_from_buffer(header)

      assert_equal [0, nil, nil, nil, nil], result
    end

    it 'parses complete response with key and value' do
      test_key = 'mykey'
      test_value = 'myvalue'
      serialized = Marshal.dump(test_value)
      body = [0x01].pack('N') + test_key + serialized # bitflags + key + value
      header = create_header(status: 0, key_len: test_key.bytesize, extra_len: 4, body_len: body.bytesize, cas: 99_999)
      full_response = header + body

      result = processor.getk_response_from_buffer(full_response)

      assert_equal 24 + body.bytesize, result[0] # advance amount
      assert result[1] # ok status
      assert_equal 99_999, result[2] # cas
      assert_equal test_key, result[3]            # key
      assert_equal test_value, result[4]          # value
    end
  end

  describe '#auth_response' do
    it 'returns [status, content] tuple' do
      content = 'auth_data'
      header = create_header(status: 0, body_len: content.bytesize)

      io_source.expect :read, header, [24]
      io_source.expect :read, content, [content.bytesize]

      status, body = processor.auth_response

      assert_equal 0, status
      assert_equal content, body
      io_source.verify
    end

    it 'raises NetworkError for unexpected format with extra_len' do
      header = create_header(status: 0, extra_len: 4, body_len: 10)

      io_source.expect :read, header, [24]

      assert_raises(Dalli::NetworkError) do
        processor.auth_response
      end
      io_source.verify
    end
  end

  describe 'error handling' do
    it 'raises DalliError for unknown error status' do
      header = create_header(status: 0x81) # Unknown command

      io_source.expect :read, header, [24]

      err = assert_raises(Dalli::DalliError) do
        processor.get
      end
      assert_includes err.message, 'Unknown command'
      io_source.verify
    end

    it 'raises NetworkError when no response' do
      io_source.expect :read, nil, [24]

      assert_raises(Dalli::NetworkError) do
        processor.get
      end
      io_source.verify
    end
  end
end
