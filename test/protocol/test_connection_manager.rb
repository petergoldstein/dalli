# frozen_string_literal: true

require_relative '../helper'

# IO#read(maxlen) on a blocking socket returns exactly maxlen bytes unless the
# stream hits EOF, where it returns a shorter (non-nil) buffer or nil. This
# models that contract deterministically: one queued result per read call, so
# we can exercise the full read and the premature-EOF cases without a real
# socket. (JRuby uses Socket#readfull, which this fake does not implement.)
class ContractReadSocket
  attr_reader :read_calls

  def initialize(*chunks)
    @chunks = chunks
    @read_calls = []
    @closed = false
  end

  def read(count)
    @read_calls << count
    @chunks.shift
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end

describe Dalli::Protocol::ConnectionManager do
  let(:hostname) { 'localhost' }
  let(:port) { 11_211 }
  let(:socket_type) { :tcp }
  let(:client_options) { {} }
  let(:connection_manager) { Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, client_options) }

  describe '#initialize' do
    it 'sets default options' do
      assert_equal 30, connection_manager.options[:down_retry_delay]
      assert_equal 1, connection_manager.options[:socket_timeout]
      assert_equal 2, connection_manager.options[:socket_max_failures]
      assert_in_delta(0.1, connection_manager.options[:socket_failure_delay])
      assert connection_manager.options[:keepalive]
    end

    it 'merges custom options with defaults' do
      custom_options = { socket_timeout: 5, down_retry_delay: 60 }
      cm = Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, custom_options)

      assert_equal 60, cm.options[:down_retry_delay]
      assert_equal 5, cm.options[:socket_timeout]
      assert_equal 2, cm.options[:socket_max_failures] # default preserved
    end
  end

  describe '#name' do
    it 'returns hostname:port for TCP sockets' do
      assert_equal 'localhost:11211', connection_manager.name
    end

    it 'returns just hostname for UNIX sockets' do
      cm = Dalli::Protocol::ConnectionManager.new('/tmp/memcached.sock', nil, :unix, {})

      assert_equal '/tmp/memcached.sock', cm.name
    end
  end

  describe '#connected?' do
    it 'returns false when socket is nil' do
      refute_predicate connection_manager, :connected?
    end

    it 'returns true when socket is present' do
      connection_manager.instance_variable_set(:@sock, Object.new)

      assert_predicate connection_manager, :connected?
    end
  end

  describe '#close' do
    it 'closes the socket and resets state' do
      socket_mock = Minitest::Mock.new
      socket_mock.expect(:close, nil)

      connection_manager.instance_variable_set(:@sock, socket_mock)
      connection_manager.instance_variable_set(:@pid, Process.pid)
      connection_manager.instance_variable_set(:@request_in_progress, true)

      connection_manager.close

      socket_mock.verify

      assert_nil connection_manager.sock
      refute_predicate connection_manager, :request_in_progress?
    end

    it 'handles socket close errors gracefully' do
      socket_mock = Object.new
      socket_mock.define_singleton_method(:close) { raise IOError, 'already closed' }

      connection_manager.instance_variable_set(:@sock, socket_mock)

      # Should not raise
      connection_manager.close

      assert_nil connection_manager.sock
    end

    it 'does nothing when socket is nil' do
      # Should not raise
      connection_manager.close

      assert_nil connection_manager.sock
    end
  end

  describe '#read size check' do
    # IO#read allocates the whole count up front, so an impossible size from
    # a hostile server is rejected before reading
    it 'rejects sizes over the largest item memcached can store, and negative sizes' do
      [(1024 * 1024 * 1024) + 3, 4 * 1024 * 1024 * 1024, -1].each do |count|
        assert_raises(Dalli::DalliError) { connection_manager.read(count) }
      end
    end
  end

  describe '#read_line length limit' do
    # Hands back what IO#gets(sep, limit) would for a stream holding `data`
    let(:socket) do
      Class.new do
        attr_reader :limits

        def initialize(data)
          @data = data
          @limits = []
        end

        def gets(sep, limit)
          @limits << limit
          idx = @data.index(sep)
          take = idx ? [idx + sep.bytesize, limit].min : [@data.bytesize, limit].min
          take.zero? ? nil : @data.slice!(0, take)
        end

        def close; end
      end
    end
    let(:client_options) { { socket_max_failures: 1 } }

    it 'passes a byte limit to gets and returns a line that fits' do
      sock = socket.new(+"HD c123\r\n")
      connection_manager.instance_variable_set(:@sock, sock)

      assert_equal "HD c123\r\n", connection_manager.read_line
      assert_equal [Dalli::Protocol::ConnectionManager::MAX_LINE_BYTES], sock.limits
    end

    it 'closes the connection when a line runs past the limit without a CRLF' do
      connection_manager.instance_variable_set(:@sock, socket.new('x' * (64 * 1024)))

      assert_raises(Dalli::NetworkError) { connection_manager.read_line }
      refute_predicate connection_manager, :connected?
    end

    it 'closes the connection when the stream ends partway through a line' do
      connection_manager.instance_variable_set(:@sock, socket.new(+'VA 5 f0'))

      assert_raises(Dalli::NetworkError) { connection_manager.read_line }
      refute_predicate connection_manager, :connected?
    end
  end

  describe 'failure counting' do
    let(:manager) { Dalli::Protocol::ConnectionManager.new('localhost', 11_211, :tcp, { socket_max_failures: 2 }) }

    it 'keeps counting failures across a reconnect until a request succeeds' do
      assert_raises(Dalli::RetryableNetworkError) { manager.error_on_request!('first failure') }
      manager.up! # a successful reconnect must not reset the count

      assert_raises(Dalli::NetworkError) { manager.error_on_request!('second failure') }
    end

    it 'resets the count when a request completes' do
      assert_raises(Dalli::RetryableNetworkError) { manager.error_on_request!('first failure') }
      manager.start_request!
      manager.finish_request!

      assert_raises(Dalli::RetryableNetworkError) { manager.error_on_request!('next failure') }
    end
  end

  describe '#request_in_progress?' do
    it 'returns false initially' do
      refute_predicate connection_manager, :request_in_progress?
    end

    it 'returns true after start_request!' do
      connection_manager.start_request!

      assert_predicate connection_manager, :request_in_progress?
    end

    it 'returns false after finish_request!' do
      connection_manager.start_request!
      connection_manager.finish_request!

      refute_predicate connection_manager, :request_in_progress?
    end
  end

  describe '#start_request!' do
    it 'sets request_in_progress to true' do
      connection_manager.start_request!

      assert_predicate connection_manager, :request_in_progress?
    end

    it 'raises when request already in progress' do
      connection_manager.start_request!

      error = assert_raises(RuntimeError) do
        connection_manager.start_request!
      end

      assert_match(/Request already in progress/, error.message)
    end
  end

  describe '#finish_request!' do
    it 'sets request_in_progress to false' do
      connection_manager.start_request!
      connection_manager.finish_request!

      refute_predicate connection_manager, :request_in_progress?
    end

    it 'raises when no request in progress' do
      error = assert_raises(RuntimeError) do
        connection_manager.finish_request!
      end

      assert_match(/No request in progress/, error.message)
    end
  end

  describe '#abort_request!' do
    it 'sets request_in_progress to false without error' do
      connection_manager.start_request!
      connection_manager.abort_request!

      refute_predicate connection_manager, :request_in_progress?
    end

    it 'does not raise when no request in progress' do
      # Should not raise
      connection_manager.abort_request!

      refute_predicate connection_manager, :request_in_progress?
    end
  end

  describe '#reconnect_down_server?' do
    it 'returns true when server has never been down' do
      assert_predicate connection_manager, :reconnect_down_server?
    end

    it 'returns false when down_retry_delay has not passed' do
      connection_manager.instance_variable_set(:@last_down_at, Time.now)

      refute_predicate connection_manager, :reconnect_down_server?
    end

    it 'returns true when down_retry_delay has passed' do
      # Set down_retry_delay to 0 for test
      cm = Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, { down_retry_delay: 0 })
      cm.instance_variable_set(:@last_down_at, Time.now - 1)

      assert_predicate cm, :reconnect_down_server?
    end
  end

  describe '#reconnect_on_fork' do
    it 'establishes a new connection after closing the old one' do
      socket_mock = Minitest::Mock.new
      socket_mock.expect(:close, nil)

      new_socket = Object.new

      connection_manager.instance_variable_set(:@sock, socket_mock)
      connection_manager.define_singleton_method(:establish_connection) do
        @sock = new_socket
      end

      with_nil_logger do
        connection_manager.reconnect_on_fork
      end

      socket_mock.verify

      assert_equal new_socket, connection_manager.sock
    end
  end

  describe 'write buffering' do
    # Records what reaches the socket, and how it was closed.
    let(:socket) do
      Class.new do
        attr_reader :written, :closed_via

        def initialize
          @written = []
        end

        def write(*parts)
          @written << parts.join
          parts.sum(&:bytesize)
        end

        def gets(_sep, _limit = nil)
          "HD\r\n"
        end

        def close
          @closed_via = :close
        end

        def to_io
          sock = self
          Object.new.tap { |io| io.define_singleton_method(:close) { sock.instance_variable_set(:@closed_via, :fd) } }
        end
      end.new
    end

    before { connection_manager.instance_variable_set(:@sock, socket) }

    it 'holds writes until flushed' do
      connection_manager.write("mn\r\n")
      connection_manager.write("mn\r\n")

      assert_empty socket.written

      connection_manager.flush

      assert_equal ["mn\r\nmn\r\n"], socket.written
    end

    # A TLS socket sends each argument of write(*parts) as its own record
    it 'sends a flush as one write of one string, joining mixed encodings as bytes' do
      calls = []
      sock = Object.new
      sock.define_singleton_method(:write) do |*parts|
        calls << parts
        parts.sum(&:bytesize)
      end
      connection_manager.instance_variable_set(:@sock, sock)
      utf8 = 'clé'
      binary = "\xFF\xFE".b

      connection_manager.write(utf8)
      connection_manager.write(binary)
      connection_manager.flush

      assert_equal 1, calls.size
      assert_equal 1, calls[0].size
      assert_equal utf8.b + binary, calls[0][0]
      assert_equal Encoding::BINARY, calls[0][0].encoding
    end

    it 'sends the buffer once it grows past the flush size' do
      big = 'x' * Dalli::Protocol::ConnectionManager::WRITE_BUFFER_FLUSH_BYTES

      connection_manager.write(big)

      assert_equal [big], socket.written
    end

    it 'sends pending writes before reading a reply' do
      connection_manager.write("mn\r\n")

      assert_equal "HD\r\n", connection_manager.read_line
      assert_equal ["mn\r\n"], socket.written
    end

    it 'discards pending writes, and closes only the file descriptor, in a forked child' do
      connection_manager.instance_variable_set(:@pid, -1) # Impossible PID
      connection_manager.write("ma counter q\r\n")

      connection_manager.close

      assert_empty socket.written
      assert_equal :fd, socket.closed_via
    end

    it 'discards pending writes when closed' do
      connection_manager.instance_variable_set(:@pid, Process.pid)
      connection_manager.write("ma counter q\r\n")

      connection_manager.close
      connection_manager.instance_variable_set(:@sock, socket)
      connection_manager.flush

      assert_empty socket.written
      assert_equal :close, socket.closed_via
    end
  end

  describe '#fork_detected?' do
    it 'returns false when pid is nil' do
      refute_predicate connection_manager, :fork_detected?
    end

    it 'returns false when pid matches current process' do
      connection_manager.instance_variable_set(:@pid, Process.pid)

      refute_predicate connection_manager, :fork_detected?
    end

    it 'returns true when pid differs from current process' do
      connection_manager.instance_variable_set(:@pid, -1) # Impossible PID

      assert_predicate connection_manager, :fork_detected?
    end
  end

  describe '#up!' do
    it 'resets down info, but not the failure count' do
      connection_manager.instance_variable_set(:@fail_count, 1)
      connection_manager.instance_variable_set(:@down_at, Time.now)
      connection_manager.instance_variable_set(:@last_down_at, Time.now)

      with_nil_logger do
        connection_manager.up!
      end

      # A reconnect alone doesn't prove the server healthy; the count resets
      # when a request completes (see 'failure counting')
      assert_equal 1, connection_manager.instance_variable_get(:@fail_count)
      assert_nil connection_manager.instance_variable_get(:@down_at)
      assert_nil connection_manager.instance_variable_get(:@last_down_at)
    end
  end

  describe '#error_on_request!' do
    it 'increments fail count' do
      initial_count = connection_manager.instance_variable_get(:@fail_count)

      with_nil_logger do
        assert_raises(Dalli::NetworkError) do
          connection_manager.error_on_request!('test error')
        end
      end

      assert_equal initial_count + 1, connection_manager.instance_variable_get(:@fail_count)
    end

    it 'marks server down after max failures' do
      cm = Dalli::Protocol::ConnectionManager.new(hostname, port, socket_type, { socket_max_failures: 1 })

      with_nil_logger do
        error = assert_raises(Dalli::NetworkError) do
          cm.error_on_request!('test error')
        end

        assert_match(/is down/, error.message)
      end
    end
  end

  unless RUBY_ENGINE == 'jruby'
    describe 'exact-length reads' do
      def connection_manager_with_socket(socket)
        manager = Dalli::Protocol::ConnectionManager.new(
          'localhost',
          11_211,
          :tcp,
          socket_failure_delay: nil,
          socket_max_failures: 2
        )
        manager.instance_variable_set(:@sock, socket)
        manager
      end

      it 'returns the full buffer from a single read, binary-safe' do
        socket = ContractReadSocket.new("a\x00\xFFz".b)
        manager = connection_manager_with_socket(socket)

        result = manager.read_exact(4)

        assert_equal "a\x00\xFFz".b, result
        assert_equal Encoding::BINARY, result.encoding
        assert_equal [4], socket.read_calls
        # #read shares the same fill semantics (both delegate to read_bytes).
        assert_equal 'xyz', connection_manager_with_socket(ContractReadSocket.new('xyz')).read(3)
      end

      it 'raises and closes the dirty socket on a premature EOF (nil)' do
        socket = ContractReadSocket.new(nil)
        manager = connection_manager_with_socket(socket)

        assert_raises(Dalli::RetryableNetworkError) { manager.read_exact(5) }
        assert_predicate socket, :closed?
        refute_predicate manager, :connected?
      end

      it 'raises and closes the dirty socket on a short read (EOF mid-response)' do
        socket = ContractReadSocket.new('abc')
        manager = connection_manager_with_socket(socket)

        assert_raises(Dalli::RetryableNetworkError) { manager.read(5) }
        assert_predicate socket, :closed?
      end
    end
  end
end
