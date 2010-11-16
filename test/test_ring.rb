require 'helper'

class TestRing < Test::Unit::TestCase

  context 'a ring of servers' do

    should "have the continuum sorted by value" do
      servers = [stub(:hostname => "localhost", :port => "11211", :weight => 1),
                 stub(:hostname => "localhost", :port => "9500", :weight => 1)]
      ring = Dalli::Ring.new(servers, {})
      previous_value = 0
      ring.continuum.each do |entry|
        assert entry.value > previous_value
        previous_value = entry.value
      end
    end

    should 'raise when no servers are available/ defined' do
      ring = Dalli::Ring.new([], {})
      assert_raise Dalli::NetworkError do
        ring.server_for_key('test')
      end
    end

  end
end
