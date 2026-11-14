# frozen_string_literal: true

require_relative '../helper'

describe 'malformed meta value reply' do
  it 'closes the connection before a later request can read leftover bytes' do
    listener = TCPServer.new('127.0.0.1', 0)
    connections = Queue.new
    workers = []
    server = Thread.new do
      loop do
        peer = listener.accept
        number = connections.size + 1
        connections << number
        workers << Thread.new(peer, number) do |socket, connection_number|
          while (line = socket.gets)
            if line == "version\r\n"
              socket.write("VERSION 1.6.45\r\n")
            elsif line.start_with?('mg ')
              if connection_number == 1 && line.include?('foo')
                # The declared value is three bytes, but the next two are not CRLF.
                socket.write("VA 3\r\nabcXYVA 4\r\nevil\r\n")
              elsif connection_number > 1
                socket.write("EN\r\n")
              end
            end
          end
        rescue IOError, SystemCallError
          nil
        ensure
          socket.close
        end
      end
    rescue IOError
      nil
    end

    client = Dalli::Client.new("127.0.0.1:#{listener.addr[1]}",
                               raw: true, socket_timeout: 0.2, socket_failure_delay: 0)

    assert_raises(Dalli::DalliError) { client.get('foo') }
    assert_nil client.get('bar')
    assert_equal 2, connections.size
  ensure
    client&.close
    listener&.close
    server&.kill
    server&.join
    workers&.each(&:kill)
    workers&.each(&:join)
  end
end
