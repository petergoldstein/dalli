# frozen_string_literal: true

require_relative '../helper'

describe 'Encoding' do
  it 'supports Unicode values' do
    memcached_persistent do |dc|
      key = 'foo'
      utf8 = 'ƒ©åÍÎ'

      assert dc.set(key, utf8)
      assert_equal utf8, dc.get(key)
    end
  end

  it 'supports Unicode keys' do
    memcached_persistent do |dc|
      utf_key = utf8 = 'ƒ©åÍÎ'

      dc.set(utf_key, utf8)

      assert_equal utf8, dc.get(utf_key)
    end
  end
end
