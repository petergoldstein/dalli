# frozen_string_literal: true

require_relative '../helper'

# memcached stops reading a connection while its replies go unread, so a
# request larger than the socket buffers used to wait on the server until
# socket_timeout, then mark it down. A Unix socket's send buffer doesn't grow
# (208 KiB by default on Linux, 8 KiB on macOS); TCP's does, so the TCP and
# TLS tests set small buffers.
describe 'requests larger than the socket buffer' do
  socket_path = File.join(Dir.tmpdir, "dalli_large_multi_get_#{Process.pid}.sock")
  tcp_port = 21_998
  tls_port = 21_999
  small_buffers = { sndbuf: 16_384, rcvbuf: 16_384 }

  def keys_and_values(count, value_bytes)
    Array.new(count) { |i| ["large-multi-get-#{i}-#{'k' * 50}", "#{i}-#{'v' * value_bytes}"] }.to_h
  end

  # Default buffers, because JRuby can't set SO_SNDBUF on a UNIX socket
  def unix_client(path)
    Dalli::Client.new(path, raw: true, socket_timeout: 1, socket_max_failures: 1)
  end

  def client_for(port, **options)
    Dalli::Client.new("localhost:#{port}", raw: true, socket_timeout: 1, socket_max_failures: 1, **options)
  end

  # Every multi-key call, with its result checked
  def assert_large_requests_work(client, expected)
    client.set_multi(expected)

    assert_equal expected, client.get_multi(expected.keys)
    assert_equal(expected, client.get_multi_with_metadata(expected.keys).transform_values { |meta| meta[:value] })
    assert_equal expected, client.get_multi_cas(*expected.keys).transform_values(&:first)

    client.delete_multi(expected.keys)

    assert_empty client.get_multi(expected.keys)
  end

  # The connection is left in step for the next request
  def assert_connection_still_works(client)
    client.set('after-large-request', 'v' * 100_000)

    10.times { assert_equal 'v' * 100_000, client.get('after-large-request') }
  end

  before do
    skip 'UNIX sockets unsupported on Windows' if RbConfig::CONFIG['host_os'].match?(/mingw|mswin/)
  end

  it 'returns every value from get_multi' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(8_000, 1_000)
      dc.set_multi(expected)

      assert_equal expected, dc.get_multi(expected.keys)
      assert_connection_still_works(dc)
      dc.close
    end
  end

  it 'returns every value from get_multi_with_metadata' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(8_000, 1_000)
      dc.set_multi(expected)

      assert_equal(expected, dc.get_multi_with_metadata(expected.keys).transform_values { |meta| meta[:value] })
      assert_connection_still_works(dc)
      dc.close
    end
  end

  it 'returns every value from get_multi_cas' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(8_000, 1_000)
      dc.set_multi(expected)

      assert_equal expected, dc.get_multi_cas(*expected.keys).transform_values(&:first)
      assert_connection_still_works(dc)
      dc.close
    end
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

  it 'returns every value from get_multi_cas when the keys are sent in chunks' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(Dalli::PipelinedGetter::INTERLEAVE_THRESHOLD + 2_000, 200)
      dc.set_multi(expected)

      assert_equal expected, dc.get_multi_cas(*expected.keys).transform_values(&:first)
      dc.close
    end
  end

  # memcached answers each quiet delete of a missing key with NF
  it 'deletes every key with delete_multi, missing or not' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(10_000, 10)
      dc.set_multi(expected.first(5_000).to_h)

      dc.delete_multi(expected.keys)

      assert_empty dc.get_multi(expected.keys)
      assert_connection_still_works(dc)
      dc.close
    end
  end

  it 'works over TCP with small socket buffers' do
    memcached_persistent(:meta, tcp_port) do
      dc = client_for(tcp_port, **small_buffers)

      assert_large_requests_work(dc, keys_and_values(8_000, 1_000))
      assert_connection_still_works(dc)
      dc.close
    end
  end

  it 'works over TLS with small socket buffers' do
    skip "jruby-openssl can't read while a write is pending" if RUBY_ENGINE == 'jruby'

    memcached_persistent(:meta, tls_port, CertificateGenerator.ssl_args,
                         { ssl_context: CertificateGenerator.ssl_context }) do
      dc = client_for(tls_port, ssl_context: CertificateGenerator.ssl_context, **small_buffers)

      assert_large_requests_work(dc, keys_and_values(8_000, 1_000))
      assert_connection_still_works(dc)
      dc.close
    end
  end

  describe 'from a server that sends but never reads the request' do
    def mock_path
      File.join(Dir.tmpdir, "dalli_never_reads_#{Process.pid}.sock")
    end

    # Answers the version check on connect, then only writes
    def never_reading_server(chunk, pause)
      lambda do |sock|
        sock.gets
        sock.write("VERSION 1.6.45\r\n")
        loop do
          sock.write(chunk)
          sleep(pause) if pause
        end
      rescue SystemCallError, IOError
        nil
      end
    end

    def elapsed(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def assert_fails_early(chunk, pause: nil, socket_timeout: 5, limit: 4, &call)
      memcached_mock(never_reading_server(chunk, pause), :start_unix, mock_path) do
        dc = Dalli::Client.new(mock_path, socket_timeout: socket_timeout, socket_max_failures: 1)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_raises(Dalli::DalliError) { Timeout.timeout(10) { yield(dc) } }
        assert_operator elapsed(started), :<, limit
      end
    end

    # Without a pause the socket is always readable, so the deadline passes
    # while replies are being read rather than in IO.select
    [0.01, nil].each do |pause|
      it "fails after socket_timeout without sending, as a blocking write does (pause #{pause.inspect})" do
        assert_fails_early("EN\r\n", pause: pause, socket_timeout: 0.5, limit: 5) do |dc|
          dc.get_multi(keys_and_values(5_000, 1).keys)
        end
      end
    end

    # Each is well before socket_timeout, so the check on what's held ended it.
    # max_response_bytes is left at its default.
    it 'fails on bytes that are no reply' do
      assert_fails_early('x' * 65_536) { |dc| dc.get_multi(keys_and_values(5_000, 1).keys) }
    end

    it 'fails on more replies than it was sent requests' do
      assert_fails_early("EN\r\n" * 16_384) { |dc| dc.get_multi(keys_and_values(5_000, 1).keys) }
    end

    it 'fails on a value larger than max_response_bytes' do
      assert_fails_early("VA 2000000 kx\r\n") { |dc| dc.delete_multi(keys_and_values(5_000, 1).keys) }
    end
  end
end
