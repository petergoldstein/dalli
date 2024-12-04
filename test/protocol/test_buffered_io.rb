# frozen_string_literal: true

require_relative '../helper'

describe 'BufferedIO' do
  before do
    @socket = StringIO.new
    @buffered_io = Dalli::Protocol::BufferedIO.new(@socket)
  end

  describe 'read_line' do
    it 'reads a line from the socket to \r\n' do
      @socket.write("test\r\n")
      @socket.rewind

      assert_equal("test\r\n", @buffered_io.read_line)
    end

    it 'eof if there is no \r\n available in the socket' do
      @socket.write('test')
      @socket.rewind

      assert_raises EOFError do
        @buffered_io.read_line
      end
    end

    it 'searches for \r\n if the data is larger than the chunk size' do
      data = 't' * Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE
      data << "\r\n"
      @socket.write(data)
      @socket.rewind

      assert_equal(data, @buffered_io.read_line)
    end

    it 'reads a line from the buffer if the data is smaller than the chunk size' do
      data = 't' * (Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE - 100)
      data << "\r\n"
      @socket.write(data)
      @socket.rewind

      assert_equal(data, @buffered_io.read_line)
    end

    it 'can read multiple lines from the socket' do
      @socket.write("test\r\nfoo\r\n")
      @socket.rewind

      assert_equal("test\r\n", @buffered_io.read_line)
      assert_equal("foo\r\n", @buffered_io.read_line)
    end

    it 'reads one line at a time if the data is larger than the chunk size' do
      data = 't' * (Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE + 100)
      data << "\r\n"
      @socket.write(data)
      data2 = 'f' * (Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE + 100)
      data2 << "\r\n"
      @socket.write(data2)
      @socket.rewind

      assert_equal(data, @buffered_io.read_line)
      assert_equal(data2, @buffered_io.read_line)
    end
  end

  describe 'read' do
    it 'reads the exact number of bytes from the socket' do
      @socket.write('test')
      @socket.rewind

      assert_equal('test', @buffered_io.read(4))
    end

    it 'gets eof if the number of bytes is larger than the socket' do
      @socket.write('test')
      @socket.rewind

      assert_raises EOFError do
        @buffered_io.read(100)
      end
    end

    it 'reads from the buffer if the number of bytes is smaller than the chunk size' do
      data = 't' * (Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE - 100)
      @socket.write(data)
      @socket.rewind

      assert_equal('t' * 100, @buffered_io.read(100))
    end

    it 'reads from the socket if the number of bytes is larger than the chunk size' do
      data = 't' * (Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE + 100)
      @socket.write(data)
      @socket.rewind

      assert_equal(data, @buffered_io.read(Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE + 100))
    end

    it 'can read multiple times from the socket' do
      data = 't' * (Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE + 100)
      @socket.write(data)
      data2 = 'f' * 100
      @socket.write(data2)
      @socket.rewind

      assert_equal(data, @buffered_io.read(Dalli::Protocol::BufferedIO::DEFAULT_CHUNK_SIZE + 100))
      assert_equal(data2, @buffered_io.read(100))
    end

    it 'gets an eof error if the socket is empty' do
      @socket.write('')
      @socket.rewind

      assert_raises EOFError do
        @buffered_io.read(100)
      end
    end
  end

  describe 'write' do
    it 'writes the exact number of bytes to the socket' do
      @buffered_io.write('test')

      assert_equal('test', @socket.string)
    end
  end
end
