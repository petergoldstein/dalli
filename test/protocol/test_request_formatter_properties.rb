# frozen_string_literal: true

require_relative '../helper'

# Property tests for request building. Whatever the caller passes, a formatter
# call must either raise ArgumentError/TypeError or produce bytes that frame as
# exactly the commands it was asked for: one line per command, value bodies of
# exactly their declared size, the key as a single clean token, and any routing
# token as exactly one flag. These are the invariants behind
# GHSA-6wmv-xq9m-fmp7, where a numeric argument could inject extra commands.
#
# Inputs are generated from a seed; set PROPERTY_SEED to reproduce a failure
# and PROPERTY_ITERATIONS to run more cases.
describe 'RequestFormatter properties' do
  formatter = Dalli::Protocol::Meta::RequestFormatter
  seed = Integer(ENV.fetch('PROPERTY_SEED', Random.new_seed.to_s))
  iterations = Integer(ENV.fetch('PROPERTY_ITERATIONS', '2000'))

  # Bytes that matter to the protocol, mixed with ordinary characters
  key_chars = [*'a'..'z', *'A'..'Z', *'0'..'9', ' ', "\t", "\r", "\n", "\0", "\x7F", 'é', '€', '😀', ':', '_']
  token_chars = [*'a'..'z', *'0'..'9', ' ', "\r", "\n", "\0", '-', 'I', 'T', 'N', 'q', 'é']

  define_method(:rng) { @rng ||= Random.new(seed) }

  define_method(:random_string) do |chars, max|
    Array.new(rng.rand(1..max)) { chars.sample(random: rng) }.join
  end

  define_method(:random_key) { random_string(key_chars, 40) }

  define_method(:random_numeric) do
    [
      -> { rng.rand(-5..(2**40)) },
      -> { rng.rand(0..100_000).to_s },
      -> { "#{rng.rand(0..9)}\r\nflush_all\r\n" },
      -> { "#{rng.rand(1..99)} I" },
      -> { ' 7 ' },
      -> { 'abc' },
      -> { 1.5 },
      -> { Object.new }
    ].sample(random: rng).call
  end

  define_method(:maybe) { |gen| rng.rand < 0.5 ? gen.call : nil }

  define_method(:random_token) do
    [nil, '', random_string(token_chars, 12)].sample(random: rng)
  end

  # Splits a request into [header, body] pairs, consuming every byte. A value
  # body follows an "ms" header and is exactly as long as its declared size.
  define_method(:frame) do |bytes|
    buf = bytes.b
    commands = []
    pos = 0
    while pos < buf.bytesize
      eol = buf.index("\r\n".b, pos) or flunk("unterminated command line: #{buf.byteslice(pos, 80).inspect}")
      header = buf.byteslice(pos, eol - pos)
      pos = eol + 2
      body = nil
      if header.start_with?('ms ')
        size = Integer(header.split[2], 10)
        body = buf.byteslice(pos, size)

        assert_equal "\r\n".b, buf.byteslice(pos + size, 2),
                     "value body not followed by its terminator: #{header.inspect}"
        pos += size + 2
      end
      commands << [header, body]
    end
    commands
  end

  define_method(:assert_command_line) do |header, key, tokens|
    words = header.b.split(' ', -1)

    refute_includes words, '', "empty token (double or trailing space) in #{header.inspect}"
    assert_includes %w[mg ms md ma], words[0], "unexpected command in #{header.inspect}"

    if Dalli::Protocol::Meta::KeyRegularizer.required?(key)
      assert_equal Dalli::Protocol::Meta::KeyRegularizer.encode(key), words[1]
      assert_includes words, 'b', "base64 key without the b flag in #{header.inspect}"
    else
      assert_equal key, words[1]
    end

    tokens.each do |flag, value|
      next if value.nil? || value.empty?

      assert_includes words, "#{flag}#{value}".b, "#{flag} token not a single flag in #{header.inspect}"
    end
  end

  # The formatter's methods and keywords differ between release lines. Calls go
  # through call_formatter, which passes only the keywords this version
  # accepts, so an unsupported keyword never looks like a rejected input.
  keyword_types = %i[key keyreq].freeze

  define_method(:keywords_for) do |name|
    formatter.method(name).parameters.filter_map { |type, param| param if keyword_types.include?(type) }
  end

  define_method(:call_formatter) do |name, *positional, **keywords|
    formatter.public_send(name, *positional, **keywords.slice(*keywords_for(name)))
  end

  # Routing tokens only count when this version's method accepts them
  define_method(:tokens_for) do |name, tokens|
    keywords_for(name).include?(:p_token) ? tokens : {}
  end

  define_method(:available) do |names|
    names.select { |name| formatter.respond_to?(name) }
  end

  # Runs one formatter call; returns nil when the input was rejected
  define_method(:attempt) do |&blk|
    blk.call
  rescue ArgumentError, TypeError
    nil
  end

  it 'frames every single-key request as exactly one well-formed command' do
    iterations.times do |i|
      key = random_key
      p_token = random_token
      l_token = random_token
      tokens = { 'P' => p_token, 'L' => l_token }
      case_name = available(%i[meta_get meta_set meta_delete meta_arithmetic plain_meta_get plain_meta_set
                               plain_meta_delete]).sample(random: rng)
      args = nil

      out = attempt do
        case case_name
        when :meta_get
          args = { key: key, ttl: maybe(-> { random_numeric }), vivify_ttl: maybe(-> { random_numeric }),
                   recache_ttl: maybe(lambda {
                     random_numeric
                   }), quiet: rng.rand < 0.5, p_token: p_token, l_token: l_token }
          call_formatter(:meta_get, **args)
        when :meta_set
          args = { key: key, value: random_string(key_chars, 30), bitflags: rng.rand(0..5), cas: maybe(lambda {
            random_numeric
          }),
                   ttl: maybe(-> { random_numeric }), quiet: rng.rand < 0.5, p_token: p_token, l_token: l_token }
          call_formatter(:meta_set, **args)
        when :meta_delete
          args = { key: key, cas: maybe(-> { random_numeric }), stale: true, ttl: maybe(-> { random_numeric }),
                   p_token: p_token, l_token: l_token }
          call_formatter(:meta_delete, **args)
        when :meta_arithmetic
          args = { key: key, delta: maybe(-> { random_numeric }), initial: maybe(-> { random_numeric }),
                   ttl: maybe(-> { random_numeric }), p_token: p_token, l_token: l_token }
          call_formatter(:meta_arithmetic, **args)
        when :plain_meta_get
          tokens = {}
          args = [key, rng.rand < 0.5]
          call_formatter(:plain_meta_get, *args)
        when :plain_meta_set
          tokens = {}
          args = [key, rng.rand(0..1000), rng.rand(0..5), maybe(-> { random_numeric })]
          call_formatter(:plain_meta_set, *args)
        when :plain_meta_delete
          tokens = {}
          args = [key]
          call_formatter(:plain_meta_delete, *args)
        end
      end
      next if out.nil?

      context = "seed=#{seed} iteration=#{i} #{case_name}(#{args.inspect})"
      bytes = case_name == :meta_set ? "#{out}#{args[:value]}\r\n" : out
      bytes = "#{out}#{'x' * args[1]}\r\n" if case_name == :plain_meta_set
      commands = frame(bytes)

      assert_equal 1, commands.size, "#{context} produced #{commands.size} commands: #{out.inspect}"
      assert_command_line(commands[0][0], key, tokens_for(case_name, tokens))
    rescue Minitest::Assertion => e
      raise e.class, "#{e.message}\n#{context || "seed=#{seed} iteration=#{i}"}"
    end
  end

  it 'frames every multi-key request as one command per key plus the terminating noop' do
    iterations.times do |i|
      keys = Array.new(rng.rand(1..5)) { random_key }.uniq
      p_token = random_token
      l_token = random_token
      tokens = { 'P' => p_token, 'L' => l_token }
      case_name = available(%i[multi_meta_get multi_meta_delete multi_meta_set]).sample(random: rng)
      args = nil

      out = attempt do
        case case_name
        when :multi_meta_get
          args = [keys, { return_cas: rng.rand < 0.5, p_token: p_token, l_token: l_token }]
          call_formatter(:multi_meta_get, keys, **args[1])
        when :multi_meta_delete
          args = [keys, { stale: true, ttl: maybe(-> { random_numeric }), p_token: p_token, l_token: l_token }]
          call_formatter(:multi_meta_delete, keys, **args[1])
        when :multi_meta_set
          entries = keys.to_h { |k| [k, [random_string(key_chars, 30), rng.rand(0..5)]] }
          args = [entries, { ttl: maybe(-> { random_numeric }), p_token: p_token, l_token: l_token }]
          call_formatter(:multi_meta_set, entries, **args[1])
        end
      end
      next if out.nil?

      context = "seed=#{seed} iteration=#{i} #{case_name}(#{args.inspect})"
      commands = frame(out)

      assert_equal keys.size + 1, commands.size, "#{context} produced #{commands.size} commands"
      assert_equal 'mn', commands.last[0], context
      commands[0...-1].each_with_index do |(header, _), idx|
        assert_command_line(header, keys[idx], tokens_for(case_name, tokens))
      end
    rescue Minitest::Assertion => e
      raise e.class, "#{e.message}\n#{context || "seed=#{seed} iteration=#{i}"}"
    end
  end
end
