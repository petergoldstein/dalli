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
    end
  end

  describe 'store' do
    let(:marshaller) { Dalli::Protocol::ValueMarshaller.new(client_options) }
    let(:client_options) { {} }
    let(:val) { SecureRandom.hex(4096) }
    let(:serialized_value) { Marshal.dump(val) }
    let(:compressed_serialized_value) { ::Dalli::Compressor.compress(serialized_value) }
    let(:compressed_raw_value) { ::Dalli::Compressor.compress(val) }
    let(:key) { SecureRandom.hex(5) }

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

          it 'return the expected value and flags' do
            assert_equal [compressed_raw_value, 0x2], marshaller.store(key, val, req_options)
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
            assert_equal "Value for #{key} over max size: #{1024 * 1024} <= #{compressed_serialized_value.size}",
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

        describe 'when the raw compressed value is above the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4 * 1024 * 1024) }

          it 'raises an error with the expected message' do
            exception = assert_raises Dalli::ValueOverMaxSize do
              marshaller.store(key, val, req_options)
            end
            assert_equal "Value for #{key} over max size: #{1024 * 1024} <= #{compressed_raw_value.size}",
                         exception.message
          end
        end

        describe 'when the value is below the value_max_bytes size and above the minimum compression size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'return the expected value and flags' do
            assert_equal [compressed_raw_value, 0x2], marshaller.store(key, val, req_options)
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
            assert_equal "Value for #{key} over max size: #{value_max_bytes} <= #{compressed_serialized_value.size}",
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

        describe 'when the raw compressed value is above the value_max_bytes size' do
          let(:val) { SecureRandom.hex(4096) }

          it 'raises an error with the expected message' do
            exception = assert_raises Dalli::ValueOverMaxSize do
              marshaller.store(key, val, req_options)
            end
            assert_equal "Value for #{key} over max size: #{value_max_bytes} <= #{compressed_raw_value.size}",
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

  describe 'retrieve' do
    let(:marshaller) { Dalli::Protocol::ValueMarshaller.new({}) }
    let(:val) { SecureRandom.hex(4096) }
    let(:serialized_value) { Marshal.dump(val) }
    let(:compressed_serialized_value) { ::Dalli::Compressor.compress(serialized_value) }
    let(:compressed_raw_value) { ::Dalli::Compressor.compress(val) }

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
