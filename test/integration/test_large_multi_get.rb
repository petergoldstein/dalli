# frozen_string_literal: true

require_relative '../helper'

# A Unix socket's send buffer doesn't grow (208 KiB by default on Linux), so
# these requests are far larger than it. The server stops reading a request
# while its replies go unread.
describe 'multi-get requests larger than the socket buffer' do
  socket_path = File.join(Dir.tmpdir, "dalli_large_multi_get_#{Process.pid}.sock")

  def keys_and_values(count, value_bytes)
    Array.new(count) { |i| ["large-multi-get-#{i}-#{'k' * 50}", "#{i}-#{'v' * value_bytes}"] }.to_h
  end

  # Default buffers, because JRuby can't set SO_SNDBUF on a UNIX socket
  def unix_client(path)
    Dalli::Client.new(path, raw: true, socket_timeout: 1, socket_max_failures: 1)
  end

  before do
    skip 'UNIX sockets unsupported on Windows' if RbConfig::CONFIG['host_os'].match?(/mingw|mswin/)
  end

  # About 140 KB: fits the send buffer, but more than the quarter of it that
  # must be free before a Unix socket accepts a second write
  it 'returns every value from get_multi_cas when the request fits the send buffer' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(1_500, 1_000)
      dc.set_multi(expected)

      assert_equal expected, dc.get_multi_cas(*expected.keys).transform_values(&:first)
      dc.close
    end
  end
end
