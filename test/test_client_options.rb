# frozen_string_literal: true

require_relative 'helper'

describe 'Dalli client options' do
  it 'not warn about valid options' do
    dc = Dalli::Client.new('foo', compress: true)
    # Rails.logger.expects :warn
    assert_operator dc.instance_variable_get(:@options), :[], :compress
  end

  describe 'caller options hash' do
    it 'does not mutate the hash passed in' do
      opts = { expires_in: '5', namespace: 'ns' }
      dc = Dalli::Client.new('foo', opts)

      assert_equal({ expires_in: '5', namespace: 'ns' }, opts)
      assert_equal 5, dc.instance_variable_get(:@options)[:expires_in]
    end

    it 'accepts a frozen options hash' do
      dc = Dalli::Client.new('foo', { expires_in: '5' }.freeze)

      assert_equal 5, dc.instance_variable_get(:@options)[:expires_in]
    end

    it 'is not affected by later changes to the hash passed in' do
      opts = { expires_in: 5, compress: false }
      dc = Dalli::Client.new('foo', opts)
      opts[:expires_in] = 10
      opts[:compress] = true

      assert_equal 5, dc.instance_variable_get(:@options)[:expires_in]
      refute dc.instance_variable_get(:@options)[:compress]
    end
  end

  describe 'servers configuration' do
    it 'default to localhost:11211' do
      dc = Dalli::Client.new
      ring = dc.send(:ring)
      s1 = ring.servers.first.hostname

      assert_equal 1, ring.servers.size
      dc.close

      dc = Dalli::Client.new('localhost:11211')
      ring = dc.send(:ring)
      s2 = ring.servers.first.hostname

      assert_equal 1, ring.servers.size
      dc.close

      dc = Dalli::Client.new(['localhost:11211'])
      ring = dc.send(:ring)
      s3 = ring.servers.first.hostname

      assert_equal 1, ring.servers.size
      dc.close

      assert_equal '127.0.0.1', s1
      assert_equal s2, s3
    end

    it 'accept comma separated string' do
      dc = Dalli::Client.new('server1.example.com:11211,server2.example.com:11211')
      ring = dc.send(:ring)

      assert_equal 2, ring.servers.size
      s1, s2 = ring.servers.map(&:hostname)

      assert_equal 'server1.example.com', s1
      assert_equal 'server2.example.com', s2
    end

    it 'accept array of servers' do
      dc = Dalli::Client.new(['server1.example.com:11211', 'server2.example.com:11211'])
      ring = dc.send(:ring)

      assert_equal 2, ring.servers.size
      s1, s2 = ring.servers.map(&:hostname)

      assert_equal 'server1.example.com', s1
      assert_equal 'server2.example.com', s2
    end

    it 'raises error when servers is a Hash' do
      assert_raises ArgumentError do
        Dalli::Client.new({ hosts: 'server1.example.com' })
      end
    end
  end
end
