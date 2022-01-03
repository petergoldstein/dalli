# frozen_string_literal: true

require_relative '../helper'

describe 'authentication' do
  describe 'using the meta protocol' do
    let(:username) { SecureRandom.hex(5) }
    it 'raises an error if the username is set' do
      err = assert_raises Dalli::DalliError do
        memcached_persistent(:meta, 21_345, '', username: username) do |dc|
          dc.flush
          dc.set('key1', 'abcd')
        end
      end
      assert_equal 'Authentication not supported for the meta protocol.', err.message
    end
  end
end
