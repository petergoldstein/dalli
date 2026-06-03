# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::Meta::KeyRegularizer do
  describe '.required?' do
    it 'returns false for simple ASCII keys' do
      key = 'simple_key_123'

      refute Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'returns false for ASCII keys with special characters' do
      key = 'key:with:colons-and_underscores.and.dots'

      refute Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'returns true for keys with spaces' do
      key = 'key with spaces'

      assert Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'returns true for keys with tabs' do
      key = "key\twith\ttabs"

      assert Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'returns true for keys with newlines' do
      key = "key\nwith\nnewlines"

      assert Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'returns true for non-ASCII keys (Unicode)' do
      key = 'clé_française'

      assert Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'returns true for emoji keys' do
      key = 'user:🎉:profile'

      assert Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end

    it 'handles empty keys' do
      key = ''

      refute Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    end
  end

  describe '.encode' do
    it 'returns the key encoded in base64 with no padding for simple ASCII keys' do
      key = 'clé_française'

      assert_equal 'Y2zDqV9mcmFuw6dhaXNl', Dalli::Protocol::Meta::KeyRegularizer.encode(key)
    end
  end

  describe '.decode' do
    it 'decodes base64 key' do
      original_key = 'key with spaces'
      encoded_key = [original_key].pack('m0')

      result = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key)

      assert_equal original_key, result
    end

    it 'forces UTF-8 encoding on decoded keys' do
      original_key = 'clé_française'
      encoded_key = [original_key].pack('m0')

      result = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key)

      assert_equal Encoding::UTF_8, result.encoding
      assert_equal original_key, result
    end

    it 'handles emoji keys' do
      original_key = 'user:🚀:data'
      encoded_key = [original_key].pack('m0')

      result = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key)

      assert_equal original_key, result
      assert_equal Encoding::UTF_8, result.encoding
    end
  end

  describe 'roundtrip' do
    it 'encode then decode returns original key with whitespace' do
      original_key = "key with\twhitespace\ncharacters"
      encoded_key = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key)

      assert_equal original_key, decoded_key
    end

    it 'encode then decode returns original Unicode key' do
      original_key = '日本語キー'
      encoded_key = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key)

      assert_equal original_key, decoded_key
    end

    it 'encode then decode returns original mixed content key' do
      original_key = 'user:日本語:profile 🎉'
      encoded_key = Dalli::Protocol::Meta::KeyRegularizer.encode(original_key)
      decoded_key = Dalli::Protocol::Meta::KeyRegularizer.decode(encoded_key)

      assert_equal original_key, decoded_key
    end
  end
end
