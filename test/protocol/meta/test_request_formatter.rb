# frozen_string_literal: true

require_relative '../../helper'

describe Dalli::Protocol::Meta::RequestFormatter do
  describe 'meta_get' do
    let(:key) { SecureRandom.hex(4) }
    let(:ttl) { rand(1000..1999) }

    it 'returns the default get (get value and bitflags, no cas) when passed only a key' do
      assert_equal "mg #{key} v f\r\n", Dalli::Protocol::Meta::RequestFormatter.meta_get(key: key)
    end

    it 'sets the TTL flag when passed a ttl' do
      assert_equal "mg #{key} v f T#{ttl}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_get(key: key, ttl: ttl)
    end

    it 'skips the value and bitflags when passed a pure touch argument' do
      assert_equal "mg #{key} T#{ttl}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_get(key: key, value: false, ttl: ttl)
    end

    it 'sets the CAS retrieval flags when passed that value' do
      assert_equal "mg #{key} c\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_get(key: key, value: false, return_cas: true)
    end

    it 'sets the flags for returning the key and body size when passed quiet' do
      assert_equal "mg #{key} v f k q s\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_get(key: key, quiet: true)
    end
  end

  describe 'meta_set' do
    let(:key) { SecureRandom.hex(4) }
    let(:hexlen) { rand(500..999) }
    let(:val) { SecureRandom.hex(hexlen) }
    let(:bitflags) { (0..3).to_a.sample }
    let(:cas) { rand(500..999) }
    let(:ttl) { rand(500..999) }

    it 'returns the default (treat as a set, no CAS check) when just passed key, datalen, and bitflags' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} MS\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags)
    end

    it 'supports the add mode' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} ME\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags,
                                                                    mode: :add)
    end

    it 'supports the replace mode' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} MR\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags,
                                                                    mode: :replace)
    end

    it 'passes a TTL if one is provided' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} T#{ttl} MS\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, ttl: ttl, bitflags: bitflags)
    end

    it 'omits the CAS flag on append' do
      assert_equal "ms #{key} #{val.bytesize} MA\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, mode: :append)
    end

    it 'omits the CAS flag on prepend' do
      assert_equal "ms #{key} #{val.bytesize} MP\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, mode: :prepend)
    end

    it 'passes a CAS if one is provided' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} C#{cas} MS\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags, cas: cas)
    end

    it 'excludes CAS if set to 0' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} MS\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags, cas: 0)
    end

    it 'excludes non-numeric CAS values' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} MS\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags,
                                                                    cas: "\nset importantkey 1 1000 8\ninjected")
    end

    it 'sets the quiet mode if configured' do
      assert_equal "ms #{key} #{val.bytesize} c F#{bitflags} MS q\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags,
                                                                    quiet: true)
    end

    it 'sets the base64 mode if configured' do
      assert_equal "ms #{key} #{val.bytesize} c b F#{bitflags} MS\r\n#{val}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_set(key: key, value: val, bitflags: bitflags,
                                                                    base64: true)
    end
  end

  describe 'meta_delete' do
    let(:key) { SecureRandom.hex(4) }
    let(:cas) { rand(1000..1999) }

    it 'returns the default when just passed key' do
      assert_equal "md #{key}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_delete(key: key)
    end

    it 'incorporates CAS when passed cas' do
      assert_equal "md #{key} C#{cas}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_delete(key: key, cas: cas)
    end

    it 'sets the q flag when passed quiet' do
      assert_equal "md #{key} q\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_delete(key: key, quiet: true)
    end

    it 'excludes CAS when set to 0' do
      assert_equal "md #{key}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_delete(key: key, cas: 0)
    end

    it 'excludes non-numeric CAS values' do
      assert_equal "md #{key}\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_delete(key: key,
                                                                       cas: "\nset importantkey 1 1000 8\ninjected")
    end

    it 'sets the base64 mode if configured' do
      assert_equal "md #{key} b\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_delete(key: key, base64: true)
    end
  end

  describe 'meta_arithmetic' do
    let(:key) { SecureRandom.hex(4) }
    let(:delta) { rand(500..999) }
    let(:initial) { rand(500..999) }
    let(:cas) { rand(500..999) }
    let(:ttl) { rand(500..999) }

    it 'returns the expected string with the default N flag when passed non-nil key, delta, and initial' do
      assert_equal "ma #{key} v D#{delta} J#{initial} N0 MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial)
    end

    it 'excludes the J and N flags when initial is nil and ttl is not set' do
      assert_equal "ma #{key} v D#{delta} MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: nil)
    end

    it 'omits the D flag is delta is nil' do
      assert_equal "ma #{key} v J#{initial} N0 MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: nil, initial: initial)
    end

    it 'uses ttl for the N flag when ttl passed explicitly along with an initial value' do
      assert_equal "ma #{key} v D#{delta} J#{initial} N#{ttl} MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial,
                                                                           ttl: ttl)
    end

    it 'incorporates CAS when passed cas' do
      assert_equal "ma #{key} v D#{delta} J#{initial} N0 C#{cas} MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial,
                                                                           cas: cas)
    end

    it 'excludes CAS when CAS is set to 0' do
      assert_equal "ma #{key} v D#{delta} J#{initial} N0 MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial,
                                                                           cas: 0)
    end

    it 'includes the N flag when ttl passed explicitly with a nil initial value' do
      assert_equal "ma #{key} v D#{delta} N#{ttl} MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: nil,
                                                                           ttl: ttl)
    end

    it 'swaps from MI to MD when the incr value is explicitly false' do
      assert_equal "ma #{key} v D#{delta} J#{initial} N0 MD\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial,
                                                                           incr: false)
    end

    it 'includes the quiet flag when specified' do
      assert_equal "ma #{key} v D#{delta} J#{initial} N0 q MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial,
                                                                           quiet: true)
    end

    it 'sets the base64 mode if configured' do
      assert_equal "ma #{key} v b D#{delta} J#{initial} N0 MI\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.meta_arithmetic(key: key, delta: delta, initial: initial,
                                                                           base64: true)
    end
  end

  describe 'meta_noop' do
    it 'returns the expected string' do
      assert_equal "mn\r\n", Dalli::Protocol::Meta::RequestFormatter.meta_noop
    end
  end

  describe 'version' do
    it 'returns the expected string' do
      assert_equal "version\r\n", Dalli::Protocol::Meta::RequestFormatter.version
    end
  end

  describe 'flush' do
    it 'returns the expected string with no arguments' do
      assert_equal "flush_all\r\n", Dalli::Protocol::Meta::RequestFormatter.flush
    end

    it 'adds noreply when quiet is true' do
      assert_equal "flush_all noreply\r\n", Dalli::Protocol::Meta::RequestFormatter.flush(quiet: true)
    end

    it 'returns the expected string with a delay argument' do
      delay = rand(1000..1999)
      assert_equal "flush_all #{delay}\r\n", Dalli::Protocol::Meta::RequestFormatter.flush(delay: delay)
    end

    it 'santizes the delay argument' do
      delay = "\nset importantkey 1 1000 8\ninjected"
      assert_equal "flush_all 0\r\n", Dalli::Protocol::Meta::RequestFormatter.flush(delay: delay)
    end

    it 'adds noreply with a delay and quiet argument' do
      delay = rand(1000..1999)
      assert_equal "flush_all #{delay} noreply\r\n",
                   Dalli::Protocol::Meta::RequestFormatter.flush(delay: delay, quiet: true)
    end
  end
end
