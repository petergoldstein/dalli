# frozen_string_literal: true

require_relative '../helper'
require 'json'

class NoopCompressor
  def self.compress(data)
    data
  end

  def self.decompress(data)
    data
  end
end

describe 'Compressor' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'default to Dalli::Compressor' do
        memcached(p, find_available_port) do |dc|
          dc.set 1, 2

          assert_equal Dalli::Compressor, dc.instance_variable_get(:@ring).servers.first.compressor
        end
      end

      it 'support a custom compressor' do
        port = find_available_port
        memcached(p, port) do |_dc|
          memcache = Dalli::Client.new("127.0.0.1:#{port}", { compressor: NoopCompressor })
          memcache.set 1, 2
          begin
            assert_equal NoopCompressor,
                         memcache.instance_variable_get(:@ring).servers.first.compressor

            memcached(p, port) do |newdc|
              assert newdc.set('string-test', 'a test string')
              assert_equal('a test string', newdc.get('string-test'))
            end
          end
        end
      end

      describe 'GzipCompressor' do
        it 'compress and uncompress data using Zlib::GzipWriter/Reader' do
          port = find_available_port
          memcached(p, port) do |_dc|
            memcache = Dalli::Client.new("127.0.0.1:#{port}", { compress: true, compressor: Dalli::GzipCompressor })
            data = (0...1025).map { rand(65..90).chr }.join

            assert memcache.set('test', data)
            assert_equal(data, memcache.get('test'))
            assert_equal Dalli::GzipCompressor, memcache.instance_variable_get(:@ring).servers.first.compressor
          end
        end
      end
    end
  end
end
