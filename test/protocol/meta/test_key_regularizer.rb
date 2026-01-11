# frozen_string_literal: true

require_relative '../../helper'

describe Dalli::Protocol::Meta::KeyRegularizer do
  describe '.encode' do
    it 'returns [key, false] for simple ASCII keys' do
      key = 'simple_key_123'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert_equal key, encoded_key
      refute base64
    end

    it 'returns [key, false] for ASCII keys with special characters' do
      key = 'key:with:colons-and_underscores.and.dots'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert_equal key, encoded_key
      refute base64
    end

    it 'returns [base64, true] for keys with spaces' do
      key = 'key with spaces'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert base64
      refute_equal key, encoded_key
      # Verify it's valid base64
      decoded = encoded_key.unpack1('m0')

      assert_equal key, decoded
    end

    it 'returns [base64, true] for keys with tabs' do
      key = "key\twith\ttabs"
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert base64
      decoded = encoded_key.unpack1('m0')

      assert_equal key, decoded
    end

    it 'returns [base64, true] for keys with newlines' do
      key = "key\nwith\nnewlines"
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert base64
      decoded = encoded_key.unpack1('m0')

      assert_equal key, decoded
    end

    it 'returns [base64, true] for non-ASCII keys (Unicode)' do
      key = 'clé_française'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert base64
      decoded = encoded_key.unpack1('m0').force_encoding(Encoding::UTF_8)

      assert_equal key, decoded
    end

    it 'returns [base64, true] for emoji keys' do
      key = 'user:🎉:profile'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      assert base64
      decoded = encoded_key.unpack1('m0').force_encoding(Encoding::UTF_8)

      assert_equal key, decoded
    end

    it 'handles empty keys' do
      key = ''
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(key)

      # Empty string is ASCII-only and has no whitespace
      assert_equal '', encoded_key
      refute base64
    end
  end

  describe '.decode' do
    it 'returns key unchanged when base64_encoded is false' do
      key = 'simple_key'
      result = Dalli::Protocol::Meta::KeyRegularizer.decode(key, false)

      assert_equal key, result
    end

    it 'decodes base64 key when base64_encoded is true' do
      original_key = 'key with spaces'
      encoded_key = [original_key].pack('m0')

      result = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, true)

      assert_equal original_key, result
    end

    it 'forces UTF-8 encoding on decoded keys' do
      original_key = 'clé_française'
      encoded_key = [original_key].pack('m0')

      result = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, true)

      assert_equal Encoding::UTF_8, result.encoding
      assert_equal original_key, result
    end

    it 'handles emoji keys' do
      original_key = 'user:🚀:data'
      encoded_key = [original_key].pack('m0')

      result = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, true)

      assert_equal original_key, result
      assert_equal Encoding::UTF_8, result.encoding
    end
  end

  describe 'roundtrip' do
    it 'encode then decode returns original ASCII key' do
      original_key = 'simple_key'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, base64)

      assert_equal original_key, decoded_key
    end

    it 'encode then decode returns original key with whitespace' do
      original_key = "key with\twhitespace\ncharacters"
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, base64)

      assert_equal original_key, decoded_key
    end

    it 'encode then decode returns original Unicode key' do
      original_key = '日本語キー'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, base64)

      assert_equal original_key, decoded_key
    end

    it 'encode then decode returns original mixed content key' do
      original_key = 'user:日本語:profile 🎉'
      encoded_key, base64 = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key, base64)

      assert_equal original_key, decoded_key
    end
  end
end
