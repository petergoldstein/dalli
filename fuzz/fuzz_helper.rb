# frozen_string_literal: true

# Shared setup for the fuzz targets. Each target feeds Dalli's reply parsing
# bytes a server could send, and fails if anything but an error Dalli means to
# raise escapes. See fuzz/README.md for running them.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'dalli'
require 'logger'

# The Marshal warning would print on every run
Dalli.logger = Logger.new(nil)

# Helpers shared by the fuzz targets
module DalliFuzz
  # Stands in for Dalli::Protocol::ConnectionManager, with the fuzz input as
  # the socket. Reads keep ConnectionManager's limits and raise
  # Dalli::NetworkError where it would, at EOF and on a line with no CRLF.
  class FakeConnection
    def initialize(data, chunk_size = nil)
      @io = StringIO.new(data)
      @chunk_size = chunk_size
    end

    def read_line
      line = @io.gets("\r\n", Dalli::Protocol::ConnectionManager::MAX_LINE_BYTES)
      raise Dalli::NetworkError, 'EOF in read_line' if line.nil?
      raise Dalli::NetworkError, 'Reply line without CRLF' unless line.end_with?("\r\n")

      line
    end

    def read(count)
      unless count.between?(0, Dalli::Protocol::ConnectionManager::MAX_READ_BYTES)
        raise Dalli::DalliError, "Reply size #{count} is out of range"
      end

      data = @io.read(count)
      raise Dalli::NetworkError, "EOF reading #{count} bytes" unless data && data.bytesize == count

      data
    end

    # Like Dalli::Socket#read_available, but in chunks of @chunk_size, so
    # replies are split across reads at the points the fuzzer picks
    def read_available(reusable_buffer = nil)
      data = @io.read(@chunk_size)
      raise Dalli::NetworkError, 'Connection reset' if data.nil?

      reusable_buffer ? reusable_buffer.replace(data) : data
    end
  end

  def self.value_marshaller
    Dalli::Protocol::ValueMarshaller.new({})
  end

  # Whether an exception from parsing a reply is one Dalli raises on purpose.
  # Anything else escaping is a bug the fuzzer reports: callers rescue
  # Dalli::DalliError, so an ArgumentError or TypeError would get past them.
  def self.expected_error?(error)
    error.is_a?(Dalli::DalliError)
  end

  # Runs block on one fuzz input, re-raising unexpected errors
  def self.run
    yield
    0
  rescue StandardError => e
    raise unless expected_error?(e)

    0
  end
end
