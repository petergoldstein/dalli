# frozen_string_literal: true

require_relative '../helper'

# A server that stops while the client is connected to it fails the request
# in progress, and the retry then finds the server down. The multi-key
# operations raise for that, as get and set do, rather than reporting the
# server's keys as misses or leaving them unwritten. A server already down
# when the operation starts is skipped, as before.
#
# Adapted from tests by @jaideeppyne in #1263.
describe 'Multi-key operations when a server stops while connected' do
  def keys = @keys ||= Array.new(40) { |i| "lost-server-key-#{i}" }

  operations = {
    get_multi: ->(client, keys) { client.get_multi(keys) },
    get_multi_cas: ->(client, keys) { client.get_multi_cas(keys) },
    get_multi_with_metadata: ->(client, keys) { client.get_multi_with_metadata(keys) },
    get_multi_with_metadata_result: ->(client, keys) { client.get_multi_with_metadata_result(keys) },
    set_multi: ->(client, keys) { client.set_multi(keys.to_h { |k| [k, 'new'] }) },
    delete_multi: ->(client, keys) { client.delete_multi(keys) }
  }.freeze

  def with_servers(count, **options)
    ports = [30_933, 30_934].first(count)
    ports.each { |port| MemcachedManager.start(port, '') }
    client_options = { failover: false, socket_timeout: 0.2, socket_failure_delay: 0.01 }.merge(options)
    client = Dalli::Client.new(ports.map { |port| "localhost:#{port}" }, client_options)
    client.flush
    keys.each { |key| client.set(key, "value-#{key}") }
    yield client, ports
  ensure
    client&.close
    ports&.each { |port| MemcachedManager.stop(port) }
  end

  # Stops the server holding the later group of keys, leaving the client's
  # connection to it open. Returns that server and the keys that were on it.
  def stop_later_server(client)
    groups = client.send(:ring).keys_grouped_by_server(keys)

    assert_equal 2, groups.size

    lost = groups.keys.last

    assert_predicate lost, :connected?
    MemcachedManager.stop(lost.port)
    [lost, groups[lost]]
  end

  operations.each do |name, operation|
    it "#{name} raises when its only server stops while connected" do
      with_servers(1) do |client, ports|
        MemcachedManager.stop(ports.first)

        assert_predicate client.send(:ring).servers.first, :connected?
        assert_raises(Dalli::NetworkError) { operation.call(client, keys) }
      end
    end

    it "#{name} raises when one of its servers stops while connected" do
      with_servers(2) do |client|
        stop_later_server(client)

        assert_raises(Dalli::NetworkError) { operation.call(client, keys) }
      end
    end

    it "#{name} leaves the keys out with failover when its only server stops" do
      with_servers(1, failover: true) do |client, ports|
        MemcachedManager.stop(ports.first)

        operation.call(client, keys)
      end
    end

    it "#{name} moves the stopped server's keys elsewhere with failover" do
      with_servers(2, failover: true) do |client|
        stop_later_server(client)

        operation.call(client, keys)
      end
    end

    it "#{name} skips a server that was down before it started" do
      with_servers(2) do |client|
        stop_later_server(client)
        client.close

        operation.call(client, keys)
      end
    end
  end

  it 'reads the surviving server and misses the moved keys with failover' do
    with_servers(2, failover: true) do |client|
      _, lost_keys = stop_later_server(client)
      expected = (keys - lost_keys).to_h { |k| [k, "value-#{k}"] }

      assert_equal expected, client.get_multi(keys)
    end
  end

  it 'writes the moved keys to the surviving server with failover' do
    with_servers(2, failover: true) do |client|
      stop_later_server(client)
      client.set_multi(keys.to_h { |k| [k, 'new'] })

      assert_equal keys.to_h { |k| [k, 'new'] }, client.get_multi(keys)
    end
  end

  it 'does not yield a partial batch from get_multi_with_metadata' do
    with_servers(2) do |client|
      stop_later_server(client)
      yielded = []

      assert_raises(Dalli::NetworkError) do
        client.get_multi_with_metadata(keys) { |key, metadata| yielded << [key, metadata] }
      end

      assert_empty yielded
    end
  end

  it 'still retries a transient error when another server was down from the start' do
    with_servers(2) do |client|
      lost, lost_keys = stop_later_server(client)
      # close builds a new ring, with new server objects
      client.close
      survivor = client.send(:ring).servers.find { |server| server.port != lost.port }
      original = survivor.method(:request)
      failed = false
      flaky = lambda do |op, *args|
        unless failed
          failed = true
          raise Dalli::RetryableNetworkError, 'injected network failure'
        end
        original.call(op, *args)
      end

      survivor.stub(:request, flaky) do
        assert_equal (keys - lost_keys).sort, client.get_multi_with_metadata(keys).keys.sort
      end
      assert failed
    end
  end

  it 'reads from a restarted server once it is back' do
    with_servers(1) do |client, ports|
      MemcachedManager.stop(ports.first)

      assert_raises(Dalli::NetworkError) { client.get_multi(keys) }

      MemcachedManager.start(ports.first, '')
      client.close
      client.set('after-restart', 'value')

      assert_equal({ 'after-restart' => 'value' }, client.get_multi('after-restart', 'missing'))
    end
  end
end
