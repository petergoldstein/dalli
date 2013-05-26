require 'helper'

describe 'Network' do

  describe 'assuming a bad network' do

    it 'handle no server available' do
      assert_raises Dalli::RingError, :message => "No server available" do
        dc = Dalli::Client.new 'localhost:19333'
        dc.get 'foo'
      end
    end

    describe 'with a fake server' do
      it 'handle connection reset' do
        memcached_mock(lambda {|sock| sock.close }) do
          assert_raises Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

      it 'handle malformed response' do
        memcached_mock(lambda {|sock| sock.write('123') }) do
          assert_raises Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

      it 'handle connect timeouts' do
        memcached_mock(lambda {|sock| sleep(0.6); sock.close }, :delayed_start) do
          assert_raises Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

      it 'handle read timeouts' do
        memcached_mock(lambda {|sock| sleep(0.6); sock.write('giraffe') }) do
          assert_raises Dalli::RingError, :message => "No server available" do
            dc = Dalli::Client.new('localhost:19123')
            dc.get('abc')
          end
        end
      end

    end

  end
end
