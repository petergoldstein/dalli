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
        memcached(p, 29_199) do |dc|
          dc.set 1, 2

          assert_equal Dalli::Compressor, dc.instance_variable_get(:@ring).servers.first.compressor
        end
      end

      # Anyone who can write to memcached can store a small value flagged as
      # compressed that expands enormously; reading it must stop at the limit
      it 'refuses to decompress a value past decompressed_max_bytes' do
        memcached(p, 29_199) do |_dc|
          bomb = Dalli::Compressor.compress("\0" * (16 * 1024 * 1024))
          sock = TCPSocket.new('127.0.0.1', 29_199)
          # The classic text protocol's set, which every memcached version accepts
          sock.write("set bomb #{Dalli::Protocol::ValueCompressor::FLAG_COMPRESSED} 0 #{bomb.bytesize}\r\n#{bomb}\r\n")

          assert_equal "STORED\r\n", sock.gets
          sock.close

          capped = Dalli::Client.new('127.0.0.1:29199', decompressed_max_bytes: 1024 * 1024, protocol: p)

          assert_raises(Dalli::UnmarshalError) { capped.get('bomb') }
          assert_equal 16 * 1024 * 1024, Dalli::Client.new('127.0.0.1:29199', protocol: p).get('bomb').bytesize
        end
      end

      it 'support a custom compressor' do
        memcached(p, 29_199) do |_dc|
          memcache = Dalli::Client.new('127.0.0.1:29199', { compressor: NoopCompressor })
          memcache.set 1, 2
          begin
            assert_equal NoopCompressor,
                         memcache.instance_variable_get(:@ring).servers.first.compressor

            memcached(p, 19_127) do |newdc|
              assert newdc.set('string-test', 'a test string')
              assert_equal('a test string', newdc.get('string-test'))
            end
          end
        end
      end

      describe 'GzipCompressor' do
        it 'compress and uncompress data using Zlib::GzipWriter/Reader' do
          memcached(p, 19_127) do |_dc|
            memcache = Dalli::Client.new('127.0.0.1:19127', { compress: true, compressor: Dalli::GzipCompressor })
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
