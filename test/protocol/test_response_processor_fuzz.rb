# frozen_string_literal: true

require_relative '../helper'

# Differential fuzzing of the reply parsers. Random, valid memcached reply
# streams for a multi-key get are fed to the pipelined parser in random-sized
# chunks, and each hit is also parsed by the single-key parser. Both must
# return exactly the generated keys and values, and the pipelined parser must
# consume the whole stream, ending at the MN. A parser that mis-frames a reply
# can leave bytes on the connection that a later command reads as its own
# reply, which is how #1170 could return one key's value for another.
#
# Inputs are generated from a seed; set PROPERTY_SEED to reproduce a failure
# and PROPERTY_ITERATIONS to run more cases.
describe 'ResponseProcessor fuzzing' do
  seed = Integer(ENV.fetch('PROPERTY_SEED', Random.new_seed.to_s))
  iterations = Integer(ENV.fetch('PROPERTY_ITERATIONS', '500'))

  key_chars = [*'a'..'z', *'A'..'Z', *'0'..'9', ':', '_', ' ', "\t", 'é']
  # Value fragments that look like protocol text, mixed with ordinary bytes
  value_parts = ['', 'x', "\r\n", "\r\nMN\r\n", 'VA 0 ', 's0', "\0", 'EN', 'é', 'abc' * 50]

  # Serves read_line / read from a fixed byte string, like the connection
  fake_io = Class.new do
    def initialize(bytes)
      @bytes = bytes.b
      @pos = 0
    end

    def read_line
      eol = @bytes.index("\r\n".b, @pos)
      return nil unless eol

      line = @bytes.byteslice(@pos, eol + 2 - @pos)
      @pos = eol + 2
      +line
    end

    def read(count)
      data = @bytes.byteslice(@pos, count)
      @pos += count
      +data
    end
  end

  define_method(:rng) { @rng ||= Random.new(seed) }
  define_method(:marshaller) { Dalli::Protocol::ValueMarshaller.new({}) }
  define_method(:processor) { |io = nil| Dalli::Protocol::Meta::ResponseProcessor.new(io, marshaller) }

  define_method(:random_key) do
    Array.new(rng.rand(1..20)) { key_chars.sample(random: rng) }.join
  end

  define_method(:random_value) do
    Array.new(rng.rand(0..4)) { value_parts.sample(random: rng) }.join.b
  end

  # One hit as memcached sends it for "mg <key> v f k q s", flags in random order
  define_method(:hit_reply) do |key, value|
    base64 = Dalli::Protocol::Meta::KeyRegularizer.required?(key)
    wire_key = base64 ? Dalli::Protocol::Meta::KeyRegularizer.encode(key) : key
    flags = ['f0', "k#{wire_key}", "s#{value.bytesize}"]
    flags << 'b' if base64
    flags << "c#{rng.rand(1..10_000)}" if rng.rand < 0.5
    "VA #{value.bytesize} #{flags.shuffle(random: rng).join(' ')}\r\n".b + value + "\r\n".b
  end

  # Drives getk_response_from_buffer the way ResponseBuffer does: append each
  # chunk, then parse complete replies from the current offset until the
  # parser asks for more data or reaches the MN.
  define_method(:parse_pipelined) do |parser, stream|
    buf = ''.b
    offset = 0
    results = {}
    finished = false
    pos = 0
    until finished || pos >= stream.bytesize
      chunk = [rng.rand(1..64), stream.bytesize - pos].min
      buf << stream.byteslice(pos, chunk)
      pos += chunk
      loop do
        response = parser.getk_response_from_buffer(buf, offset)
        break if response == [0]

        offset += response.last
        if response.size == 5
          _status, _cas, key, value = response
          flunk("duplicate result for #{key.inspect}") if results.key?(key)
          results[key] = value
        else
          finished = true
          break
        end
      end
    end
    [results, finished, buf.bytesize - offset, stream.bytesize - pos]
  end

  it 'agrees between the pipelined and single-key parsers on random reply streams' do
    token_only = processor
    token_only.define_singleton_method(:va_response_from_buffer) { |*| nil }

    iterations.times do |i|
      expected = Array.new(rng.rand(1..8)) { [random_key, random_value] }.uniq(&:first).to_h
      stream = expected.map { |k, v| hit_reply(k, v) }.join.b + "MN\r\n".b
      context = "seed=#{seed} iteration=#{i} replies=#{stream.inspect}"

      [processor, token_only].each do |parser|
        results, finished, left_in_buffer, left_unread = parse_pipelined(parser, stream)

        assert finished, "parser never reached the MN: #{context}"
        assert_equal 0, left_in_buffer, "bytes left unparsed after the MN: #{context}"
        assert_equal 0, left_unread, "stream ended early (MN seen too soon): #{context}"
        assert_equal(expected.transform_keys(&:b).transform_values(&:b),
                     results.transform_keys(&:b).transform_values(&:b), context)
      end

      expected.each do |key, value|
        io = fake_io.new("VA #{value.bytesize} f0\r\n".b + value + "\r\n".b)

        assert_equal value.b, processor(io).meta_get_with_value.b, "single-key parse of #{key.inspect}: #{context}"
      end
    end
  end
end
