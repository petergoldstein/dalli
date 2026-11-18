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

  it 'returns every value from get_multi' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(8_000, 1_000)
      dc.set_multi(expected)

      assert_equal expected, dc.get_multi(expected.keys)
      dc.close
    end
  end

  it 'returns every value from get_multi_with_metadata' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(8_000, 1_000)
      dc.set_multi(expected)

      assert_equal(expected, dc.get_multi_with_metadata(expected.keys).transform_values { |meta| meta[:value] })
      dc.close
    end
  end

  it 'returns every value from get_multi_cas' do
    memcached_persistent(:meta, socket_path) do |_, path|
      dc = unix_client(path)
      expected = keys_and_values(8_000, 1_000)
      dc.set_multi(expected)

      assert_equal expected, dc.get_multi_cas(*expected.keys).transform_values(&:first)
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

  describe 'from a server that sends but never reads the request' do
    mock_path = File.join(Dir.tmpdir, "dalli_never_reads_#{Process.pid}.sock")

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

    # Without a pause the socket is always readable, so the deadline passes
    # while replies are being read rather than in IO.select
    [0.01, nil].each do |pause|
      it "fails after socket_timeout without sending, as a blocking write does (pause #{pause.inspect})" do
        memcached_mock(never_reading_server('x', pause), :start_unix, mock_path) do
          dc = Dalli::Client.new(mock_path, socket_timeout: 0.5, socket_max_failures: 1)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          assert_raises(Dalli::DalliError) { Timeout.timeout(10) { dc.get_multi(keys_and_values(5_000, 1).keys) } }
          assert_operator elapsed(started), :<, 5
        end
      end
    end

    it 'fails once it holds more reply bytes than the keys could need' do
      memcached_mock(never_reading_server('x' * 65_536, nil), :start_unix, mock_path) do
        dc = Dalli::Client.new(mock_path, socket_timeout: 5, socket_max_failures: 1, max_response_bytes: 100)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_raises(Dalli::DalliError) { Timeout.timeout(10) { dc.get_multi(keys_and_values(5_000, 1).keys) } }
        # Well before socket_timeout, so the byte limit ended it
        assert_operator elapsed(started), :<, 4
      end
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
end
