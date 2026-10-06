# frozen_string_literal: true

require_relative '../helper'

# A request made with raw: true doesn't ask for flags, so it must return the
# stored bytes even when the reply carries flags anyway (a proxy, a broken or
# hostile server). Only the client decides whether a value is deserialized.
describe 'raw reads with flags the server sends unasked' do
  next unless MemcachedManager.supported_protocols.include?(:meta)

  # Answers every get with a hit flagged as serialized (f1)
  def with_flag_adding_server(payload)
    server = TCPServer.new('127.0.0.1', 19_458)
    acceptor = Thread.new do
      loop do
        Thread.new(server.accept) do |sock|
          while (line = sock.gets)
            words = line.split
            case words.first
            when 'version' then sock.write("VERSION 1.6.45\r\n")
            when 'mn' then sock.write("MN\r\n")
            when 'mg'
              key = words[1]
              b = words.include?('b') ? ' b' : ''
              # Key and size where memcached puts them for this request, with
              # the flags it never asked for added at the end
              sock.write("VA #{payload.bytesize} k#{key}#{b} s#{payload.bytesize} f1 c7\r\n#{payload}\r\n")
            end
          end
        rescue IOError, SystemCallError
          nil
        end
      end
    rescue IOError
      nil
    end
    yield Dalli::Client.new('127.0.0.1:19458', socket_timeout: 1)
  ensure
    server&.close
    acceptor&.kill
  end

  let(:payload) { Marshal.dump('deserialized') }

  it 'returns the stored bytes from every raw read' do
    with_flag_adding_server(payload) do |dc|
      assert_equal payload, dc.get('k', raw: true)
      assert_equal payload, dc.gat('k', 60, raw: true)
      assert_equal payload, dc.get_cas('k', raw: true).first
      assert_equal payload, dc.get_with_metadata('k', raw: true)[:value]
      assert_equal payload, dc.get_multi_cas('k', 'j', req_options: { raw: true })['k'].first
      assert_equal({ 'k' => payload, 'j' => payload }, dc.get_multi('k', 'j', req_options: { raw: true }))

      # Without raw, the flags in the reply still apply
      assert_equal 'deserialized', dc.get('k')
    end
  end
end
