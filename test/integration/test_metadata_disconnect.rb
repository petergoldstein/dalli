# frozen_string_literal: true

require_relative '../helper'

describe 'Bulk metadata reads after a real disconnect' do
  def with_disconnect_servers(count, **options)
    ports = [30_933, 30_934].first(count)
    ports.each { |port| MemcachedManager.start(port, '') }
    client_options = { failover: false, socket_timeout: 0.2, socket_failure_delay: 0.01 }.merge(options)
    client = Dalli::Client.new(ports.map { |port| "localhost:#{port}" }, client_options)
    client.flush
    yield client, ports
  ensure
    client&.close
    ports&.each { |port| MemcachedManager.stop(port) }
  end

  %i[get_multi_with_metadata get_multi_with_metadata_result].each do |operation|
    it "raises from #{operation} when a connected single server disconnects and refuses reconnect" do
      with_disconnect_servers(1) do |client, ports|
        client.set('present', 'value')
        server = client.send(:ring).servers.first

        assert_predicate server, :connected?

        MemcachedManager.stop(ports.first)

        # The local socket is still present, so the first request really
        # reaches the I/O path rather than starting with an unroutable key.
        assert_predicate server, :connected?
        assert_raises(Dalli::NetworkError) { client.public_send(operation, 'present') }
      end
    end
  end

  it 'does not yield a single-server failure as a successful empty batch' do
    with_disconnect_servers(1) do |client, ports|
      client.set('present', 'value')
      MemcachedManager.stop(ports.first)
      yielded = []

      assert_raises(Dalli::NetworkError) do
        client.get_multi_with_metadata('present') { |key, metadata| yielded << [key, metadata] }
      end

      assert_empty yielded
    end
  end

  def disconnect_later_group(client)
    keys = Array.new(40) { |i| "disconnect-key-#{i}" }
    keys.each { |key| client.set(key, "value-#{key}") }
    groups = client.send(:ring).keys_grouped_by_server(keys)

    assert_equal 2, groups.size

    failed = groups.keys.last

    assert_predicate failed, :connected?

    MemcachedManager.stop(failed.port)
    keys
  end

  %i[get_multi_with_metadata get_multi_with_metadata_result].each do |operation|
    it "raises from #{operation} instead of omitting a disconnected server after regrouping" do
      with_disconnect_servers(2) do |client|
        keys = disconnect_later_group(client)

        assert_raises(Dalli::NetworkError) { client.public_send(operation, keys) }
      end
    end

    it "raises from #{operation} instead of hiding the failed request through default failover" do
      with_disconnect_servers(2, failover: true) do |client|
        keys = disconnect_later_group(client)

        assert_raises(Dalli::NetworkError) { client.public_send(operation, keys) }
      end
    end
  end

  it 'does not yield the surviving server as a successful partial batch' do
    with_disconnect_servers(2) do |client|
      keys = disconnect_later_group(client)
      yielded = []

      assert_raises(Dalli::NetworkError) do
        client.get_multi_with_metadata(keys) { |key, metadata| yielded << [key, metadata] }
      end

      assert_empty yielded
    end
  end

  it 'does not yield fallback misses as success after a request fails with default failover' do
    with_disconnect_servers(2, failover: true) do |client|
      keys = disconnect_later_group(client)
      yielded = []

      assert_raises(Dalli::NetworkError) do
        client.get_multi_with_metadata(keys) { |key, metadata| yielded << [key, metadata] }
      end

      assert_empty yielded
    end
  end

  it 'keeps the initially unavailable server behavior unchanged' do
    with_disconnect_servers(1) do |client, ports|
      MemcachedManager.stop(ports.first)
      client.close

      assert_empty client.get_multi_with_metadata('absent')
    end
  end

  it 'still reconnects to a restarted server and reads a real miss' do
    with_disconnect_servers(1) do |client, ports|
      client.set('present', 'old-value')
      MemcachedManager.stop(ports.first)
      MemcachedManager.start(ports.first, '')

      assert_empty client.get_multi_with_metadata('present')

      client.set('present', 'new-value')

      assert_equal 'new-value', client.get_multi_with_metadata('present')['present'][:value]
    end
  end

  it 'keeps failover when a server is unavailable before the batch is routed' do
    with_disconnect_servers(2, failover: true) do |client, ports|
      ring = client.send(:ring)
      candidates = (1..).lazy.map { |i| "initial-failover-#{i}" }
      key = candidates.find { |candidate| ring.server_for_key(candidate) == ring.servers.first }
      fallback = single_server_client(ports.last)
      begin
        fallback.set(key, 'fallback-value')
        MemcachedManager.stop(ports.first)
        client.close

        assert_equal 'fallback-value', client.get_multi_with_metadata(key)[key][:value]
      ensure
        fallback.close
      end
    end
  end
end
