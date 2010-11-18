require 'helper'

class TestNetwork < Test::Unit::TestCase

  context 'assuming a bad network' do

    should 'handle no server available' do
      assert_raise Dalli::RingError, :message => "No server available" do
        dc = Dalli::Client.new 'localhost:19333'
        dc.get 'foo'
      end
    end

    context 'with a fake server' do
      should 'handle connection reset' do
        memcached_mock(lambda {|sock| sock.close }) do
          assert_raise Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

      should 'handle malformed response' do
        memcached_mock(lambda {|sock| sock.write('123') }) do
          assert_raise Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

      should 'handle connect timeouts' do
        memcached_mock(lambda {|sock| sleep(0.6); sock.close }, :delayed_start) do
          assert_raise Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

      should 'handle read timeouts' do
        memcached_mock(lambda {|sock| sleep(0.6); sock.write('giraffe') }) do
          assert_raise Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

    end

  end
end
