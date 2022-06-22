# frozen_string_literal: true

require_relative 'helper'

describe 'KeyManager' do
  describe 'options' do
    let(:key_manager) { Dalli::KeyManager.new(options) }

    describe 'digest_class' do
      describe 'when there is no explicit digest_class parameter provided' do
        let(:options) { {} }

        it 'uses Digest::MD5 as a default' do
          assert_equal ::Digest::MD5, key_manager.digest_class
        end
      end

      describe 'when there is an explicit digest_class parameter provided' do
        describe 'and the class implements hexdigest' do
          let(:options) { { digest_class: ::Digest::SHA2 } }

          it 'uses the specified argument' do
            assert_equal ::Digest::SHA2, key_manager.digest_class
          end
        end

        describe 'and the class does not implement hexdigest' do
          let(:options) { { digest_class: Object.new } }

          it 'raises an argument error' do
            err = assert_raises ArgumentError do
              key_manager
            end
            assert_equal 'The digest_class object must respond to the hexdigest method', err.message
          end
        end
      end
    end

    describe 'namespace' do
      describe 'when there is no explicit namespace parameter provided' do
        let(:options) { {} }

        it 'the namespace is nil' do
          assert_nil key_manager.namespace
        end
      end

      describe 'when there is an explicit String provided as a namespace parameter' do
        let(:options) { { namespace: namespace_as_s } }
        let(:namespace_as_s) { SecureRandom.hex(5) }

        it 'the namespace is the string' do
          assert_equal namespace_as_s, key_manager.namespace
        end
      end

      describe 'when there is an explicit symbol provided as a namespace parameter' do
        let(:options) { { namespace: namespace_as_symbol } }
        let(:namespace_as_symbol) { namespace_as_s.to_sym }
        let(:namespace_as_s) { SecureRandom.hex(5) }

        it 'the namespace is the stringified symbol' do
          assert_equal namespace_as_s, key_manager.namespace
        end
      end

      describe 'when there is a Proc provided as a namespace parameter' do
        let(:options) { { namespace: namespace_as_proc } }
        let(:namespace_as_proc) { proc { namespace_as_symbol } }
        let(:namespace_as_symbol) { namespace_as_s.to_sym }
        let(:namespace_as_s) { SecureRandom.hex(5) }

        it 'the namespace is the proc' do
          assert_equal namespace_as_proc, key_manager.namespace
        end

        it 'the evaluated namespace is the stringified symbol' do
          assert_equal namespace_as_s, key_manager.evaluate_namespace
        end
      end

      describe 'when the namespace Proc returns dynamic results' do
        count = 0

        let(:options) { { namespace: namespace_as_proc } }
        let(:namespace_as_proc) do
          proc { count += 1 }
        end

        it 'evaluates the namespace proc every time we need it' do
          assert_equal 0, count
          assert_equal '1', key_manager.evaluate_namespace
          assert_equal(/\A2:/, key_manager.namespace_regexp)
          assert_equal '3', key_manager.evaluate_namespace
          assert_equal '4:test', key_manager.key_with_namespace('test')
        end
      end
    end
  end

  describe 'validate_key' do
    subject { key_manager.validate_key(key) }

    describe 'when there is no namespace' do
      let(:key_manager) { ::Dalli::KeyManager.new(options) }
      let(:options) { {} }

      describe 'when the key is nil' do
        let(:key) { nil }

        it 'raises an error' do
          err = assert_raises ArgumentError do
            subject
          end
          assert_equal 'key cannot be blank', err.message
        end
      end

      describe 'when the key is empty' do
        let(:key) { '' }

        it 'raises an error' do
          err = assert_raises ArgumentError do
            subject
          end
          assert_equal 'key cannot be blank', err.message
        end
      end

      describe 'when the key is blank, but not empty' do
        let(:keylen) { rand(1..5) }
        let(:key) { Array.new(keylen) { [' ', '\t', '\n'].sample }.join }

        it 'returns the key' do
          assert_equal key, subject
        end
      end

      describe 'when the key is shorter than 250 characters' do
        let(:keylen) { rand(1..250) }
        let(:alphanum) { [('a'..'z').to_a, ('A'..'Z').to_a, ('0'..'9').to_a].flatten }
        let(:key) { Array.new(keylen) { alphanum.sample }.join }

        it 'returns the key' do
          assert_equal keylen, key.length
          assert_equal key, subject
        end
      end

      describe 'when the key is longer than 250 characters' do
        let(:keylen) { rand(251..500) }
        let(:alphanum) { [('a'..'z').to_a, ('A'..'Z').to_a, ('0'..'9').to_a].flatten }
        let(:key) { Array.new(keylen) { alphanum.sample }.join }

        describe 'when there is no digest_class parameter' do
          let(:truncated_key) { "#{key[0, 212]}:md5:#{::Digest::MD5.hexdigest(key)}" }

          it 'returns the truncated key' do
            assert_equal 249, subject.length
            assert_equal truncated_key, subject
          end
        end

        describe 'when there is a custom digest_class parameter' do
          let(:options) { { digest_class: ::Digest::SHA2 } }
          let(:truncated_key) { "#{key[0, 180]}:md5:#{::Digest::SHA2.hexdigest(key)}" }

          it 'returns the truncated key' do
            assert_equal 249, subject.length
            assert_equal truncated_key, subject
          end
        end
      end
    end

    describe 'when there is a namespace' do
      let(:key_manager) { ::Dalli::KeyManager.new(options) }
      let(:half_namespace_len) { rand(1..5) }
      let(:namespace_as_s) { SecureRandom.hex(half_namespace_len) }
      let(:options) { { namespace: namespace_as_s } }

      describe 'when the key is nil' do
        let(:key) { nil }

        it 'raises an error' do
          err = assert_raises ArgumentError do
            subject
          end
          assert_equal 'key cannot be blank', err.message
        end
      end

      describe 'when the key is empty' do
        let(:key) { '' }

        it 'raises an error' do
          err = assert_raises ArgumentError do
            subject
          end
          assert_equal 'key cannot be blank', err.message
        end
      end

      describe 'when the key is blank, but not empty' do
        let(:keylen) { rand(1..5) }
        let(:key) { Array.new(keylen) { [' ', '\t', '\n'].sample }.join }

        it 'returns the key' do
          assert_equal "#{namespace_as_s}:#{key}", subject
        end
      end

      describe 'when the key with namespace is shorter than 250 characters' do
        let(:keylen) { rand(250 - (2 * half_namespace_len)) + 1 }
        let(:alphanum) { [('a'..'z').to_a, ('A'..'Z').to_a, ('0'..'9').to_a].flatten }
        let(:key) { Array.new(keylen) { alphanum.sample }.join }

        it 'returns the key' do
          assert_equal keylen, key.length
          assert_equal "#{namespace_as_s}:#{key}", subject
        end
      end

      describe 'when the key with namespace is longer than 250 characters' do
        let(:keylen) { rand(251..500) - (2 * half_namespace_len) }
        let(:alphanum) { [('a'..'z').to_a, ('A'..'Z').to_a, ('0'..'9').to_a].flatten }
        let(:key) { Array.new(keylen) { alphanum.sample }.join }

        describe 'when there is no digest_class parameter' do
          let(:key_prefix) { key[0, 212 - (2 * half_namespace_len)] }
          let(:truncated_key) do
            "#{namespace_as_s}:#{key_prefix}:md5:#{::Digest::MD5.hexdigest("#{namespace_as_s}:#{key}")}"
          end

          it 'returns the truncated key' do
            assert_equal 250, subject.length
            assert_equal truncated_key, subject
          end
        end

        describe 'when there is a custom digest_class parameter' do
          let(:options) { { digest_class: ::Digest::SHA2, namespace: namespace_as_s } }
          let(:key_prefix) { key[0, 180 - (2 * half_namespace_len)] }
          let(:truncated_key) do
            "#{namespace_as_s}:#{key_prefix}:md5:#{::Digest::SHA2.hexdigest("#{namespace_as_s}:#{key}")}"
          end

          it 'returns the truncated key' do
            assert_equal 250, subject.length
            assert_equal truncated_key, subject
          end
        end
      end
    end
  end

  describe 'key_with_namespace' do
    let(:raw_key) { SecureRandom.hex(10) }
    let(:key_manager) { ::Dalli::KeyManager.new(options) }
    subject { key_manager.key_with_namespace(raw_key) }

    describe 'without namespace' do
      let(:options) { {} }

      it 'returns the argument' do
        assert_equal raw_key, subject
      end
    end

    describe 'with namespace' do
      let(:namespace_as_s) { SecureRandom.hex(5) }
      let(:options) { { namespace: namespace_as_s } }

      it 'returns the argument with the namespace prepended' do
        assert_equal "#{namespace_as_s}:#{raw_key}", subject
      end
    end
  end

  describe 'key_without_namespace' do
    let(:key_manager) { ::Dalli::KeyManager.new(options) }
    subject { key_manager.key_without_namespace(raw_key) }

    describe 'without namespace' do
      let(:options) { {} }

      describe 'when the key has no colon' do
        let(:raw_key) { SecureRandom.hex(10) }

        it 'returns the argument' do
          assert_equal raw_key, subject
        end
      end

      describe 'when the key has a colon' do
        let(:raw_key) { "#{SecureRandom.hex(5)}:#{SecureRandom.hex(10)}" }

        it 'returns the argument' do
          assert_equal raw_key, subject
        end
      end
    end

    describe 'with namespace' do
      let(:namespace_as_s) { SecureRandom.hex(5) }
      let(:options) { { namespace: namespace_as_s } }

      describe 'when the argument starts with the namespace' do
        let(:key_wout_namespace) { SecureRandom.hex(5) }
        let(:raw_key) { "#{namespace_as_s}:#{key_wout_namespace}" }

        it 'strips the namespace' do
          assert_equal key_wout_namespace, subject
        end
      end

      describe 'when the argument includes the namespace in a position other than the start' do
        let(:raw_key) { "#{SecureRandom.hex(5)}#{namespace_as_s}:#{SecureRandom.hex(5)}" }

        it 'returns the argument' do
          assert_equal raw_key, subject
        end
      end

      describe 'when the argument does not include the namespace' do
        let(:raw_key) { SecureRandom.hex(10) }

        it 'returns the argument' do
          assert_equal raw_key, subject
        end
      end
    end
  end
end
