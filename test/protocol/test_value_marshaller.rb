# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ValueMarshaller do
  describe 'options' do
    subject { Dalli::Protocol::ValueMarshaller.new(options) }

    describe 'value_max_bytes' do
      describe 'by default' do
        let(:options) { {} }

        it 'sets value_max_bytes to 1MB by default' do
          assert_equal(1024 * 1024, subject.value_max_bytes)
        end
      end

      describe 'with a user specified value' do
        let(:value_max_bytes) { rand(4 * 1024 * 1024) + 1 }
        let(:options) { { value_max_bytes: value_max_bytes } }

        it 'sets value_max_bytes to the user specified value' do
          assert_equal subject.value_max_bytes, value_max_bytes
        end
      end

      describe 'with a String value' do
        let(:options) { { value_max_bytes: '2048' } }

        it 'converts it to an Integer' do
          assert_equal 2048, subject.value_max_bytes
        end

        it 'enforces the limit when storing' do
          assert_equal ['abc', 0x0], subject.store('key', 'abc', raw: true)
          assert_raises(Dalli::ValueOverMaxSize) { subject.store('key', 'a' * 2048, raw: true, compress: false) }
        end
      end
    end
  end

  describe 'store' do
    let(:marshaller) { Dalli::Protocol::ValueMarshaller.new(client_options) }
    let(:client_options) { {} }
    let(:val) { SecureRandom.hex(4096) }
    let(:serialized_value) { Marshal.dump(val) }
    let(:compressed_serialized_value) { Dalli::Compressor.compress(serialized_value) }
    let(:key) { SecureRandom.hex(5) }
    let(:over_max_message) do
      lambda do |max, value|
        overhead = Dalli::Protocol::ValueMarshaller::ITEM_OVERHEAD_BYTES
        "Value for #{key} over max size: #{max} <= #{value.bytesize + key.bytesize + overhead} " \
          "(#{value.bytesize} value bytes + #{key.bytesize} key bytes + #{overhead} item overhead)"
      end
    end

    describe 'when the bytesize is under value_max_bytes' do
      describe 'when the raw option is not specified' do
        let(:req_options) { {} }

        describe 'when the serialized value is above the minimum compression size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'return the expected value and flags' do
            assert_equal [compressed_serialized_value, 0x3], marshaller.store(key, val, req_options)
          end
        end

        describe 'when the value is below the minimum compression size' do
          let(:val) { SecureRandom.hex(128) }

          it 'return the expected value and flags' do
            assert_equal [serialized_value, 0x1], marshaller.store(key, val, req_options)
          end
        end
      end

      describe 'when the raw option is specified' do
        let(:req_options) { { raw: true } }

        describe 'when the value is above the minimum compression size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'returns the value uncompressed' do
            assert_equal [val, 0x0], marshaller.store(key, val, req_options)
          end
        end

        describe 'when the value is below the minimum compression size' do
          let(:val) { SecureRandom.hex(128) }

          it 'return the expected value and flags' do
            assert_equal [val, 0x0], marshaller.store(key, val, req_options)
          end
        end
      end
    end

    describe 'when the value_max_bytes is the default 1MB' do
      let(:client_options) { {} }

      describe 'when the raw option is not specified' do
        let(:req_options) { {} }

        describe 'when the compressed, serialized value is above the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4 * 1024 * 1024) }

          it 'raises an error with the expected message' do
            exception = assert_raises Dalli::ValueOverMaxSize do
              marshaller.store(key, val, req_options)
            end

            assert_equal over_max_message.call(1024 * 1024, compressed_serialized_value),
                         exception.message
          end
        end

        describe 'when the serialized value is below the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'return the expected value and flags' do
            assert_equal [compressed_serialized_value, 0x3], marshaller.store(key, val, req_options)
          end
        end

        describe 'when the serialized value is below the value_max_bytes size and min compression size' do
          let(:val) { SecureRandom.hex(128) }

          it 'return the expected value and flags' do
            assert_equal [serialized_value, 0x1], marshaller.store(key, val, req_options)
          end
        end
      end

      describe 'when the raw option is specified' do
        let(:req_options) { { raw: true } }

        describe 'when the raw value is above the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4 * 1024 * 1024) }

          it 'raises an error with the expected message' do
            exception = assert_raises Dalli::ValueOverMaxSize do
              marshaller.store(key, val, req_options)
            end

            assert_equal over_max_message.call(1024 * 1024, val),
                         exception.message
          end
        end

        describe 'when the value is below the value_max_bytes size and above the minimum compression size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'returns the value uncompressed' do
            assert_equal [val, 0x0], marshaller.store(key, val, req_options)
          end
        end

        describe 'when the raw value is below the value_max_bytes size and min compression size' do
          let(:val) { SecureRandom.hex(128) }

          it 'return the expected value and flags' do
            assert_equal [val, 0x0], marshaller.store(key, val, req_options)
          end
        end
      end
    end

    describe 'when the value_max_bytes is customized' do
      let(:value_max_bytes) { 512 }
      let(:client_options) { { value_max_bytes: value_max_bytes } }

      describe 'when the raw option is not specified' do
        let(:req_options) { {} }

        describe 'when the compressed, serialized value is above the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'raises an error with the expected message' do
            exception = assert_raises Dalli::ValueOverMaxSize do
              marshaller.store(key, val, req_options)
            end

            assert_equal over_max_message.call(value_max_bytes, compressed_serialized_value),
                         exception.message
          end
        end

        describe 'when the serialized value is below the value_max_bytes size and min compression size' do
          let(:val) { SecureRandom.hex(128) }

          it 'return the expected value and flags' do
            assert_equal [serialized_value, 0x1], marshaller.store(key, val, req_options)
          end
        end
      end

      describe 'when the raw option is specified' do
        let(:req_options) { { raw: true } }

        describe 'when the raw value is above the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'raises an error with the expected message' do
            exception = assert_raises Dalli::ValueOverMaxSize do
              marshaller.store(key, val, req_options)
            end

            assert_equal over_max_message.call(value_max_bytes, val),
                         exception.message
          end
        end

        describe 'when the raw value is below the value_max_bytes size and min compression size' do
          let(:val) { SecureRandom.hex(128) }

          it 'return the expected value and flags' do
            assert_equal [val, 0x0], marshaller.store(key, val, req_options)
          end
        end
      end
    end
  end

  describe 'item size limit' do
    # memcached rejects an item whose value, key and per-item header together
    # exceed its -I limit, so value_max_bytes is checked against all three.
    let(:value_max_bytes) { 1024 }
    let(:overhead) { Dalli::Protocol::ValueMarshaller::ITEM_OVERHEAD_BYTES }
    let(:key) { 'k' * 10 }
    let(:largest_value_size) { value_max_bytes - key.bytesize - overhead }
    let(:req_options) { { raw: true, compress: false } }

    it 'uses the measured worst-case memcached item overhead' do
      assert_equal 63, overhead
    end

    [Dalli::Protocol::ValueMarshaller, Dalli::Protocol::StringMarshaller].each do |klass|
      describe klass.name do
        let(:marshaller) { klass.new(value_max_bytes: value_max_bytes) }

        it 'accepts the largest value whose item fits' do
          value = 'a' * largest_value_size

          assert_equal [value, 0x0], marshaller.store(key, value, req_options)
        end

        it 'rejects a value one byte larger' do
          value = 'a' * (largest_value_size + 1)
          exception = assert_raises Dalli::ValueOverMaxSize do
            marshaller.store(key, value, req_options)
          end

          assert_equal "Value for #{key} over max size: #{value_max_bytes} <= #{value_max_bytes + 1} " \
                       "(#{value.bytesize} value bytes + #{key.bytesize} key bytes + #{overhead} item overhead)",
                       exception.message
        end

        it 'counts a longer key against the limit' do
          value = 'a' * largest_value_size

          assert_raises(Dalli::ValueOverMaxSize) { marshaller.store("#{key}k", value, req_options) }
        end
      end
    end

    it 'converts a String value_max_bytes in StringMarshaller' do
      marshaller = Dalli::Protocol::StringMarshaller.new(value_max_bytes: '2048')

      assert_equal 2048, marshaller.value_max_bytes
    end
  end

  describe 'retrieve' do
    let(:marshaller) { Dalli::Protocol::ValueMarshaller.new({}) }
    let(:val) { SecureRandom.hex(4096) }
    let(:serialized_value) { Marshal.dump(val) }
    let(:compressed_serialized_value) { Dalli::Compressor.compress(serialized_value) }
    let(:compressed_raw_value) { Dalli::Compressor.compress(val) }

    it 'retrieves the value when the flags indicate the value is both compressed and serialized' do
      assert_equal val, marshaller.retrieve(compressed_serialized_value, 0x3)
    end

    it 'retrieves the value when the flags indicate the value is just compressed' do
      assert_equal val, marshaller.retrieve(compressed_raw_value, 0x2)
    end

    it 'retrieves the value when the flags indicate the value is just serialized' do
      assert_equal val, marshaller.retrieve(serialized_value, 0x1)
    end

    it 'retrieves the value when the flags indicate the value is neither compressed nor serialized' do
      assert_equal val, marshaller.retrieve(val, 0x0)
    end
  end
end
