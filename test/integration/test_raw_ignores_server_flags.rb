# frozen_string_literal: true

require_relative '../helper'

# A request made with raw: true doesn't ask for flags, so it must return the
# stored bytes even when the reply carries flags anyway (a proxy, a broken or
# hostile server). Only the client decides whether a value is deserialized.
describe 'raw reads with flags the server sends unasked' do
  next unless MemcachedManager.supported_protocols.include?(:meta)

  # Answers every get with a hit flagged as serialized (f1)
  def answer(sock, line, payload)
    words = line.split
    case words.first
    when 'version' then sock.write("VERSION 1.6.45\r\n")
    when 'mn' then sock.write("MN\r\n")
    when 'ms'
      sock.read(words[2].to_i + 2)
      sock.write("HD\r\n")
    when 'mg'
      # Key and size where memcached puts them for this request, with the
      # flags it never asked for added at the end
      b = words.include?('b') ? ' b' : ''
      sock.write("VA #{payload.bytesize} k#{words[1]}#{b} s#{payload.bytesize} f1 c7\r\n#{payload}\r\n")
    end
  end

  def with_flag_adding_server(payload)
    server = TCPServer.new('127.0.0.1', 19_458)
    acceptor = Thread.new do
      loop do
        Thread.new(server.accept) do |sock|
          while (line = sock.gets)
            answer(sock, line, payload)
          end
        rescue IOError, SystemCallError
          nil
        end
      end
    rescue IOError
      nil
    end
    yield Dalli::Client.new('127.0.0.1:19458', socket_timeout: 1, protocol: :meta)
  ensure
    server&.close
    acceptor&.kill
  end

  let(:payload) { Marshal.dump('deserialized') }

  it 'returns the stored bytes from every raw read' do
    with_flag_adding_server(payload) do |dc|
      # This line's multi-get methods and get_cas take no per-request options
      assert_equal payload, dc.get('k', raw: true)
      assert_equal payload, dc.get_with_metadata('k', raw: true)[:value]
      seen = nil
      dc.cas('k', nil, raw: true) { |v| seen = v }

      assert_equal payload, seen

      # Without raw, the flags in the reply still apply
      assert_equal 'deserialized', dc.get('k')
    end
  end
end
