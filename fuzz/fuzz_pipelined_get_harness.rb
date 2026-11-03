# frozen_string_literal: true

require_relative 'fuzz_helper'
require 'ruzzy'

# The replies to a get_multi, parsed from a buffer as Protocol::Base#
# pipeline_next_responses parses them. The first byte sets how many bytes
# each socket read returns, and bit 0 whether the request was raw.
MARSHALLER = DalliFuzz.value_marshaller

test_one_input = lambda do |data|
  return 0 if data.empty?

  control = data.getbyte(0)
  connection = DalliFuzz::FakeConnection.new(data.byteslice(1..), (control >> 1) + 1)
  buffer = Dalli::Protocol::ResponseBuffer.new(
    connection, Dalli::Protocol::Meta::ResponseProcessor.new(connection, MARSHALLER)
  )
  buffer.raw = control.odd?
  buffer.reset

  DalliFuzz.run do
    loop do
      buffer.read
      status, _cas, key, = buffer.process_single_getk_response
      until status.nil?
        # The noop (MN) that ends the pipeline
        break if status && key.nil?

        status, _cas, key, = buffer.process_single_getk_response
      end
      break if status && key.nil?
    end
  end
end

Ruzzy.fuzz(test_one_input)
