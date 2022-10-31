# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ValueSerializer do
  describe 'options' do
    subject { Dalli::Protocol::ValueSerializer.new(options) }

    describe 'serializer' do
      describe 'when the serializer option is unspecified' do
        let(:options) { {} }

        it 'defaults to Marshal' do
          assert_equal subject.serializer, ::Marshal
        end
      end

      describe 'when the serializer option is explicitly specified' do
        let(:dummy_serializer) { Object.new }
        let(:options) { { serializer: dummy_serializer } }

        it 'uses the explicit option' do
          assert_equal subject.serializer, dummy_serializer
        end
      end
    end
  end

  describe 'store' do
    let(:bitflags) { rand(32) }
    let(:serializer) { Minitest::Mock.new }
    let(:serialized_dummy) { SecureRandom.hex(8) }
    let(:serializer_options) { { serializer: serializer } }
    let(:vs) { Dalli::Protocol::ValueSerializer.new(vs_options) }
    let(:vs_options) { { serializer: serializer } }
    let(:raw_value) { Object.new }

    describe 'when the request options are nil' do
      let(:req_options) { nil }

      it 'serializes the value' do
        serializer.expect :dump, serialized_dummy, [raw_value]
        val, newbitflags = vs.store(raw_value, req_options, bitflags)

        assert_equal val, serialized_dummy
        assert_equal newbitflags, (bitflags | 0x1)
        serializer.verify
      end
    end

    describe 'when the request options do not specify a value for the :raw key' do
      let(:req_options) { { other: SecureRandom.hex(4) } }

      it 'serializes the value' do
        serializer.expect :dump, serialized_dummy, [raw_value]
        val, newbitflags = vs.store(raw_value, req_options, bitflags)

        assert_equal val, serialized_dummy
        assert_equal newbitflags, (bitflags | 0x1)
        serializer.verify
      end
    end

    describe 'when the request options value for the :raw key is false' do
      let(:req_options) { { raw: false } }

      it 'serializes the value' do
        serializer.expect :dump, serialized_dummy, [raw_value]
        val, newbitflags = vs.store(raw_value, req_options, bitflags)

        assert_equal val, serialized_dummy
        assert_equal newbitflags, (bitflags | 0x1)
        serializer.verify
      end
    end

    describe 'when the request options value for the :raw key is true' do
      let(:req_options) { { raw: true } }

      it 'does not call the serializer and just converts the input value to a string' do
        val, newbitflags = vs.store(raw_value, req_options, bitflags)

        assert_equal val, raw_value.to_s
        assert_equal newbitflags, bitflags
        serializer.verify
      end
    end

    describe 'when serialization raises a TimeoutError' do
      let(:error_message) { SecureRandom.hex(10) }
      let(:serializer) { Marshal }
      let(:req_options) { {} }

      it 'reraises the Timeout::Error' do
        error = ->(_arg) { raise Timeout::Error, error_message }
        serializer.stub :dump, error do
          exception = assert_raises Timeout::Error do
            vs.store(raw_value, req_options, bitflags)
          end

          assert_equal exception.message, error_message
        end
      end
    end

    describe 'when serialization raises an Error that is not a TimeoutError' do
      let(:error_message) { SecureRandom.hex(10) }
      let(:serializer) { Marshal }
      let(:req_options) { {} }

      it 'translates that into a MarshalError' do
        error = ->(_arg) { raise StandardError, error_message }
        serializer.stub :dump, error do
          exception = assert_raises Dalli::MarshalError do
            vs.store(raw_value, req_options, bitflags)
          end

          assert_equal exception.message, error_message
        end
      end
    end

    describe 'when serialization raises an Error that is not a TimeoutError' do
      let(:error_message) { SecureRandom.hex(10) }
      let(:serializer) { Marshal }
      let(:req_options) { {} }

      it 'translates that into a MarshalError' do
        error = ->(_arg) { raise StandardError, error_message }
        serializer.stub :dump, error do
          exception = assert_raises Dalli::MarshalError do
            vs.store(raw_value, req_options, bitflags)
          end

          assert_equal exception.message, error_message
        end
      end
    end
  end

  describe 'retrieve' do
    let(:raw_value) { SecureRandom.hex(8) }
    let(:deserialized_dummy) { SecureRandom.hex(8) }
    let(:serializer) { Minitest::Mock.new }
    let(:vs_options) { { serializer: serializer } }
    let(:vs) { Dalli::Protocol::ValueSerializer.new(vs_options) }

    describe 'when the bitflags do not specify serialization' do
      it 'should return the value without deserializing' do
        bitflags = rand(32)
        bitflags &= 0xFFFE

        assert_equal(0, bitflags & 0x1)
        assert_equal vs.retrieve(raw_value, bitflags), raw_value
        serializer.verify
      end
    end

    describe 'when the bitflags specify serialization' do
      it 'should deserialize the value' do
        serializer.expect :load, deserialized_dummy, [raw_value]
        bitflags = rand(32)
        bitflags |= 0x1

        assert_equal(0x1, bitflags & 0x1)
        assert_equal vs.retrieve(raw_value, bitflags), deserialized_dummy
        serializer.verify
      end
    end

    describe 'when deserialization raises a TypeError for needs to have method `_load' do
      let(:error_message) { "needs to have method `_load'" }
      let(:serializer) { Marshal }

      # TODO: Determine what scenario causes this error
      it 'raises UnmarshalError on uninitialized constant' do
        error = ->(_arg) { raise TypeError, error_message }
        exception = serializer.stub :load, error do
          assert_raises Dalli::UnmarshalError do
            vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
          end
        end

        assert_equal exception.message, "Unable to unmarshal value: #{error_message}"
      end
    end

    describe 'when deserialization raises a TypeError for exception class/object expected' do
      let(:error_message) { 'exception class/object expected' }
      let(:serializer) { Marshal }

      # TODO: Determine what scenario causes this error
      it 'raises UnmarshalError on uninitialized constant' do
        error = ->(_arg) { raise TypeError, error_message }
        exception = serializer.stub :load, error do
          assert_raises Dalli::UnmarshalError do
            vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
          end
        end

        assert_equal exception.message, "Unable to unmarshal value: #{error_message}"
      end
    end

    describe 'when deserialization raises an TypeError for an instance of IO needed' do
      let(:error_message) { 'instance of IO needed' }
      let(:serializer) { Marshal }
      let(:raw_value) { Object.new }

      it 'raises UnmarshalError on uninitialized constant' do
        exception = assert_raises Dalli::UnmarshalError do
          vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
        end

        assert_equal exception.message, "Unable to unmarshal value: #{error_message}"
      end
    end

    describe "when deserialization raises an TypeError for an incompatible marshal file format (can't be read)" do
      let(:error_message) { "incompatible marshal file format (can't be read)" }
      let(:serializer) { Marshal }
      let(:raw_value) { '{"a":"b"}' }

      it 'raises UnmarshalError on uninitialized constant' do
        exception = assert_raises Dalli::UnmarshalError do
          vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
        end

        assert exception.message.start_with?("Unable to unmarshal value: #{error_message}")
      end
    end

    describe 'when deserialization raises a TypeError with a non-matching message' do
      let(:error_message) { SecureRandom.hex(10) }
      let(:serializer) { Marshal }

      it 're-raises TypeError' do
        error = ->(_arg) { raise TypeError, error_message }
        exception = serializer.stub :load, error do
          assert_raises TypeError do
            vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
          end
        end

        assert_equal error_message, exception.message
      end
    end

    describe 'when deserialization raises a NameError for an uninitialized constant' do
      let(:error_message) { 'uninitialized constant Ddd' }
      let(:serializer) { Marshal }

      # TODO: Determine what scenario causes this error
      it 'raises UnmarshalError on uninitialized constant' do
        error = ->(_arg) { raise NameError, error_message }
        exception = serializer.stub :load, error do
          assert_raises Dalli::UnmarshalError do
            vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
          end
        end

        assert exception.message.start_with?("Unable to unmarshal value: #{error_message}")
      end
    end

    describe 'when deserialization raises a NameError with a non-matching message' do
      let(:error_message) { SecureRandom.hex(10) }
      let(:serializer) { Marshal }

      it 're-raises NameError' do
        error = ->(_arg) { raise NameError, error_message }
        exception = serializer.stub :load, error do
          assert_raises NameError do
            vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
          end
        end

        assert exception.message.start_with?(error_message)
      end
    end

    describe 'when deserialization raises an ArgumentError for an undefined class' do
      let(:error_message) { 'undefined class/module NonexistentClass' }
      let(:serializer) { Marshal }
      let(:raw_value) { "\x04\bo:\x15NonexistentClass\x00" }

      it 'raises UnmarshalError on uninitialized constant' do
        exception = assert_raises Dalli::UnmarshalError do
          vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
        end

        assert_equal exception.message, "Unable to unmarshal value: #{error_message}"
      end
    end

    describe 'when deserialization raises an ArgumentError for marshal data too short' do
      let(:error_message) { 'marshal data too short' }
      let(:serializer) { Marshal }
      let(:raw_value) { "\x04\bo:\vObj" }

      it 'raises UnmarshalError on uninitialized constant' do
        exception = assert_raises Dalli::UnmarshalError do
          vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
        end

        assert_equal exception.message, "Unable to unmarshal value: #{error_message}"
      end
    end

    describe 'when deserialization raises an ArgumentError with a non-matching message' do
      let(:error_message) { SecureRandom.hex(10) }
      let(:serializer) { Marshal }

      it 're-raises ArgumentError' do
        error = ->(_arg) { raise ArgumentError, error_message }
        exception = serializer.stub :load, error do
          assert_raises ArgumentError do
            vs.retrieve(raw_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
          end
        end

        assert_equal exception.message, error_message
      end
    end

    describe 'when using the default serializer' do
      let(:deserialized_value) { SecureRandom.hex(1024) }
      let(:serialized_value) { Marshal.dump(deserialized_value) }
      let(:vs_options) { {} }
      let(:vs) { Dalli::Protocol::ValueSerializer.new(vs_options) }

      it 'properly deserializes the serialized value' do
        assert_equal vs.retrieve(serialized_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED),
                     deserialized_value
      end

      it 'raises UnmarshalError for non-seriaized data' do
        assert_raises Dalli::UnmarshalError do
          vs.retrieve(:not_serialized_value, Dalli::Protocol::ValueSerializer::FLAG_SERIALIZED)
        end
      end
    end
  end
end
