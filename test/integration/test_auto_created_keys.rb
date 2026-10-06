# frozen_string_literal: true

require_relative '../helper'
require 'socket'

# memcached stores an item made by auto-create (ma, or mg with N) for a
# base64-encoded key without its binary-key flag, and later replies name it by
# its raw key bytes, without the b flag. Dalli no longer creates counters that
# way, and with verify_reply_keys a multi-get ignores replies for keys it
# didn't request.
describe 'Keys that need base64 encoding' do
  next unless MemcachedManager.supported_protocols.include?(:meta)

  # Creates an item the way earlier Dalli versions did for incr with an initial value
  def auto_create(port, key)
    sock = TCPSocket.new('127.0.0.1', port)
    sock.write("ma #{[key].pack('m0')} b N0 J5 q\r\nmn\r\n")
    sock.gets
  ensure
    sock&.close
  end

  def reply_line_for(port, key)
    sock = TCPSocket.new('127.0.0.1', port)
    sock.write("mg #{[key].pack('m0')} b v k s\r\n")
    sock.gets
  ensure
    sock&.close
  end

  it 'creates counters that memcached names by their base64 key' do
    memcached_persistent(:meta) do |dc, port|
      dc.flush

      assert_equal 5, dc.incr('é', 1, 0, 5)
      assert_equal 6, dc.incr('é', 1)
      assert_equal 4, dc.decr('é', 2)
      dc.quiet { dc.incr('ü', 1, 0, 7) }

      assert_equal "VA 1 k#{['é'].pack('m0')} b s1\r\n", reply_line_for(port, 'é')
      assert_equal({ 'é' => '4', 'ü' => '7' }, dc.get_multi('é', 'ü'))
    end
  end

  it 'ignores replies for keys that were not requested, with verify_reply_keys' do
    memcached_persistent(:meta) do |_, port|
      dc = Dalli::Client.new("127.0.0.1:#{port}", protocol: :meta, verify_reply_keys: true)
      dc.flush
      dc.set('victim', 'secret-value', 0, raw: true)
      odd = "z s1\r\nVA 6 f0 kvictim s6\r\nFORGED"
      auto_create(port, odd)

      yielded = []
      dc.get_multi('victim', odd) { |k, v| yielded << [k, v] }

      refute_includes yielded.map(&:last), 'FORGED'
      refute_includes dc.get_multi('victim', odd).values, 'FORGED'
      refute_includes dc.get_multi_cas('victim', odd).values.map(&:first), 'FORGED'
      assert_equal 'secret-value', dc.get('victim')
    end
  end

  it 'checks reply keys only when asked to' do
    memcached_persistent(:meta) do |dc, _|
      server = dc.send(:ring).servers.first
      server.send(:expect_reply_keys, %w[a b])

      assert_nil server.instance_variable_get(:@expected_reply_keys)
    end
  end
end
