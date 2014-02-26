require 'helper'

describe Dalli::Server do
  describe 'ttl translation' do
    it 'does not translate ttls under 30 days' do
      s = Dalli::Server.new('localhost')
      assert_equal s.send(:sanitize_ttl, 30*24*60*60), 30*24*60*60
    end

    it 'translates ttls over 30 days into timestamps' do
      s = Dalli::Server.new('localhost')
      assert_equal s.send(:sanitize_ttl, 30*24*60*60 + 1), Time.now.to_i + 30*24*60*60+1
    end
  end
end
