# frozen_string_literal: true

require_relative '../helper'

describe 'Bulk metadata reads with network errors' do
  def with_metadata_client(server_count = 1)
    memcached_persistent(:meta, 21_345) do |_, first_port|
      if server_count == 1
        yield single_server_client(first_port, namespace: 'app')
      else
        memcached_persistent(:meta, 21_346) do |_, second_port|
          yield Dalli::Client.new(["localhost:#{first_port}", "localhost:#{second_port}"], namespace: 'app')
        end
      end
    end
  end

  # The real request is used after deterministic fault injection, so successful
  # retries still exercise serialization, metadata parsing and key routing.
  def with_metadata_faults(server, errors)
    original = server.method(:request)
    attempts = []
    faulty_request = lambda do |operation, *args|
      if operation == :read_multi_with_metadata_req
        attempts << args.first.dup
        error = errors[attempts.size - 1]
        raise error, 'injected network failure' if error
      end

      original.call(operation, *args)
    end
    server.stub(:request, faulty_request) { yield attempts }
  end

  it 'retries a single-server metadata read without applying the namespace twice' do
    with_metadata_client do |client|
      client.flush
      client.set('key', 'value')
      expected = client.get_multi_with_metadata(%w[key absent])
      server = client.send(:ring).servers.first

      with_metadata_faults(server, [Dalli::RetryableNetworkError]) do |attempts|
        assert_equal expected, client.get_multi_with_metadata(%w[key absent])
        assert_equal [%w[app:key app:absent], %w[app:key app:absent]], attempts
      end

      assert_equal 'value', client.get('key')
    end
  end

  it 'raises a terminal network error from a single-server metadata read' do
    with_metadata_client do |client|
      client.set('key', 'value')
      server = client.send(:ring).servers.first

      with_metadata_faults(server, [Dalli::NetworkError]) do |attempts|
        assert_raises(Dalli::NetworkError) { client.get_multi_with_metadata('key') }
        assert_equal 1, attempts.size
      end
    end
  end

  it 'raises when a single-server metadata retry becomes a terminal failure' do
    with_metadata_client do |client|
      server = client.send(:ring).servers.first

      with_metadata_faults(server, [Dalli::RetryableNetworkError, Dalli::NetworkError]) do |attempts|
        assert_raises(Dalli::NetworkError) { client.get_multi_with_metadata('key') }
        assert_equal [%w[app:key], %w[app:key]], attempts
      end
    end
  end

  def seed_metadata_servers(client)
    client.flush
    keys = Array.new(40) { |i| "key#{i}" }
    keys.each { |key| client.set(key, "value-#{key}") }
    groups = client.send(:ring).keys_grouped_by_server(keys.map { |key| "app:#{key}" })

    assert_equal 2, groups.size, 'the read must span both servers'
    [keys, groups.keys.last]
  end

  it 'retries a multi-server metadata read and returns all servers results' do
    with_metadata_client(2) do |client|
      keys, second = seed_metadata_servers(client)
      expected = client.get_multi_with_metadata(keys)

      with_metadata_faults(second, [Dalli::RetryableNetworkError]) do |attempts|
        assert_equal expected, client.get_multi_with_metadata(keys)
        assert_equal 2, attempts.size
        assert_equal attempts.first, attempts.last
      end

      assert_equal "value-#{keys.first}", client.get(keys.first)
    end
  end

  it 'raises instead of returning partial metadata when a later server fails' do
    with_metadata_client(2) do |client|
      keys, second = seed_metadata_servers(client)

      with_metadata_faults(second, [Dalli::NetworkError]) do |attempts|
        assert_raises(Dalli::NetworkError) { client.get_multi_with_metadata(keys) }
        assert_equal 1, attempts.size
      end

      assert_equal "value-#{keys.first}", client.get(keys.first)
    end
  end

  it 'does not yield partial metadata to the block when a later server fails' do
    with_metadata_client(2) do |client|
      keys, second = seed_metadata_servers(client)
      yielded = []

      with_metadata_faults(second, [Dalli::NetworkError]) do
        assert_raises(Dalli::NetworkError) do
          client.get_multi_with_metadata(keys) { |key, value| yielded << [key, value] }
        end
      end

      assert_empty yielded
    end
  end

  it 'propagates terminal failures through the CacheResult adapter' do
    with_metadata_client do |client|
      server = client.send(:ring).servers.first

      with_metadata_faults(server, [Dalli::NetworkError]) do
        assert_raises(Dalli::NetworkError) { client.get_multi_with_metadata_result('key') }
      end
    end
  end
end
