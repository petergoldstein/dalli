# frozen_string_literal: true

require_relative '../helper'

# Accepts connections and answers the version check on connect (unless
# answer_version is false), then reads requests without answering them. With
# stop_reading, it stops reading after the version check, as memcached does
# while its replies go unread
class SilentServer
  attr_reader :port

  def initialize(answer_version: true, stop_reading: false)
    @answer_version = answer_version
    @stop_reading = stop_reading
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @mutex = Mutex.new
    @commands = []
    @threads = []
    @acceptor = Thread.new { accept_connections }
  end

  def address
    "127.0.0.1:#{port}"
  end

  # How many requests with this command (such as 'mg') arrived
  def count(command)
    @mutex.synchronize { @commands.count(command) }
  end

  def close
    @server.close
    @acceptor.kill
    @mutex.synchronize { @threads.each(&:kill) }
  end

  private

  def accept_connections
    loop do
      sock = @server.accept
      @mutex.synchronize { @threads << Thread.new { serve(sock) } }
    end
  rescue IOError, SystemCallError
    nil
  end

  def serve(sock)
    while (line = sock.gets("\r\n"))
      command, _key, size = line.split
      sock.read(size.to_i + 2) if command == 'ms'
      @mutex.synchronize { @commands << command }
      next unless command == 'version' && @answer_version

      sock.write("VERSION 1.6.45\r\n")
      sleep if @stop_reading
    end
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close
  end
end

describe 'Dalli::Client#with_deadline' do
  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def with_client(servers, **options)
    client = Dalli::Client.new(servers, **options)
    yield client
  ensure
    client&.close
  end

  def connection_manager(client, index = 0)
    client.send(:ring).servers[index].instance_variable_get(:@connection_manager)
  end

  # memcached_persistent's client has two servers, localhost and 127.0.0.1,
  # so look up the one the key is sent to
  def connection_manager_for(client, key)
    client.send(:ring).server_for_key(key).instance_variable_get(:@connection_manager)
  end

  describe 'against a server that never answers' do
    before do
      @servers = Array.new(2) { SilentServer.new }
    end

    after do
      @servers.each(&:close)
    end

    # Only where CRuby's IO#timeout= or enforce_read_timeout bounds the read
    it 'raises DeadlineExceededError without retrying or counting a failure' do
      skip 'reads need IO#timeout= or enforce_read_timeout' unless RUBY_ENGINE == 'ruby'

      with_client(@servers.first.address, socket_timeout: 2, socket_failure_delay: 0) do |client|
        took = elapsed do
          assert_raises(Dalli::DeadlineExceededError) { client.with_deadline(0.2) { client.get('key') } }
        end

        assert_operator took, :<, 1
        assert_equal 1, @servers.first.count('mg')
        manager = connection_manager(client)

        assert_equal 0, manager.instance_variable_get(:@fail_count)
        assert_nil manager.instance_variable_get(:@down_at)
        refute_predicate manager, :connected?
      end
    end

    it 'bounds get_multi across servers' do
      with_client(@servers.map(&:address), socket_timeout: 2) do |client|
        took = elapsed do
          assert_raises(Dalli::DeadlineExceededError) do
            client.with_deadline(0.2) { client.get_multi(Array.new(20) { |i| "key#{i}" }) }
          end
        end

        assert_operator took, :<, 1
        2.times do |i|
          assert_equal 0, connection_manager(client, i).instance_variable_get(:@fail_count)
        end
      end
    end

    it 'bounds set_multi across servers' do
      skip 'reads need IO#timeout= or enforce_read_timeout' unless RUBY_ENGINE == 'ruby'

      with_client(@servers.map(&:address), socket_timeout: 2) do |client|
        took = elapsed do
          assert_raises(Dalli::DeadlineExceededError) do
            client.with_deadline(0.2) { client.set_multi(Array.new(20) { |i| ["key#{i}", 'v'] }.to_h) }
          end
        end

        assert_operator took, :<, 1
      end
    end
  end

  it 'bounds a large request the server stops reading' do
    server = SilentServer.new(stop_reading: true)
    keys = Array.new(50_000) { |i| format('%<i>0200d', i: i) }
    with_client(server.address, socket_timeout: 5, sndbuf: 16_384) do |client|
      took = elapsed do
        assert_raises(Dalli::DeadlineExceededError) { client.with_deadline(0.3) { client.get_multi(keys) } }
      end

      assert_operator took, :<, 2
      manager = connection_manager(client)

      assert_equal 0, manager.instance_variable_get(:@fail_count)
      assert_nil manager.instance_variable_get(:@down_at)
    end
  ensure
    server&.close
  end

  it 'bounds a connect that gets no answer to its version check' do
    server = SilentServer.new(answer_version: false)
    with_client(server.address, socket_timeout: 2) do |client|
      took = elapsed do
        assert_raises(Dalli::DeadlineExceededError) { client.with_deadline(0.2) { client.get('key') } }
      end

      assert_operator took, :<, 1
      assert_equal 0, connection_manager(client).instance_variable_get(:@fail_count)
    end
  ensure
    server&.close
  end

  describe 'against memcached' do
    it 'runs calls that finish in time as usual' do
      memcached_persistent do |dc|
        result = dc.with_deadline(5) do
          dc.set('deadline_key', 'value')
          dc.get_multi('deadline_key', 'missing')
        end

        assert_equal({ 'deadline_key' => 'value' }, result)
      end
    end

    it 'raises before sending once the deadline has passed, keeping the connection' do
      memcached_persistent do |dc|
        dc.set('deadline_key', 'value')
        manager = connection_manager_for(dc, 'deadline_key')

        assert_raises(Dalli::DeadlineExceededError) { dc.with_deadline(0) { dc.get('deadline_key') } }
        assert_predicate manager, :connected?
        assert_equal 'value', dc.get('deadline_key')
      end
    end

    it "restores the socket's timeout after a request it cut short" do
      skip 'IO#timeout= is how CRuby applies it' unless RUBY_ENGINE == 'ruby'

      memcached_persistent(:meta, 21_345, '', socket_timeout: 1) do |dc|
        dc.get('deadline_key')
        dc.with_deadline(0.5) { dc.get('deadline_key') }

        assert_equal 1, connection_manager_for(dc, 'deadline_key').sock.timeout
      end
    end
  end
end
