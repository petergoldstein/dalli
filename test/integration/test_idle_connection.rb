# frozen_string_literal: true

require_relative '../helper'

# memcached's idle_timeout (like a load balancer or firewall) closes a
# connection that sat unused. The next write still succeeds, so without a
# check first the request counts as sent when the read fails, and one that
# isn't safe to send twice raises instead of being retried.
describe 'A connection the server closed while it was idle' do
  def port = 31_778

  def with_idle_timeout_server(client_options = {})
    MemcachedManager.start(port, '-o idle_timeout=1')
    client = Dalli::Client.new("localhost:#{port}", { socket_failure_delay: 0.01 }.merge(client_options))
    client.flush
    yield client
  ensure
    client&.close
    MemcachedManager.stop(port)
  end

  # memcached checks for idle connections every few seconds
  def wait_for_server_close(client)
    sock = client.send(:ring).servers.first.sock.to_io
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until sock.wait_readable(0)
      flunk 'memcached never closed the idle connection' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
  end

  it 'reconnects before a request that is not safe to send twice' do
    with_idle_timeout_server do |client|
      client.set('counter', '0', 0, raw: true)
      wait_for_server_close(client)

      assert_equal 1, client.incr('counter', 1)

      wait_for_server_close(client)

      assert client.add('new-key', 'value')
      assert_equal 'value', client.get('new-key')
    end
  end

  # With socket_max_failures: 1, a single failed attempt marks the server
  # down, so these would raise if the closed connection were used first
  it 'reconnects without counting a failure toward socket_max_failures' do
    with_idle_timeout_server(socket_max_failures: 1) do |client|
      client.set('key', 'value', 0, raw: true)
      wait_for_server_close(client)

      assert_equal 'value', client.get('key', raw: true)

      wait_for_server_close(client)

      assert client.append('key', '-more')
      assert_equal 'value-more', client.get('key', raw: true)
    end
  end
end
