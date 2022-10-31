# frozen_string_literal: true

require_relative '../helper'

describe 'Encoding' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'supports Unicode values' do
        memcached_persistent(p) do |dc|
          key = 'foo'
          utf8 = 'ƒ©åÍÎ'

          assert dc.set(key, utf8)
          assert_equal utf8, dc.get(key)
        end
      end

      it 'supports Unicode keys' do
        memcached_persistent(p) do |dc|
          utf_key = utf8 = 'ƒ©åÍÎ'

          dc.set(utf_key, utf8)

          assert_equal utf8, dc.get(utf_key)
        end
      end
    end
  end
end
