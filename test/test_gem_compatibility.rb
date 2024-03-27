# frozen_string_literal: true

# JRuby does not support forking, and it doesn't seem worth the effort to make it work.
return unless Process.respond_to?(:fork)

require_relative 'helper'

describe 'gem compatibility' do
  %w[
    resolv-replace
    socksify
  ].each do |gem_name|
    it "passes smoke test with #{gem_name.inspect} gem required" do
      memcached(:binary, rand(21_397..21_896)) do |_, port|
        in_isolation(timeout: 10) do
          before_client = Dalli::Client.new("127.0.0.1:#{port}")

          assert_round_trip(before_client, "Failed to round-trip key before requiring #{gem_name.inspect}")

          require gem_name

          after_client = Dalli::Client.new("127.0.0.1:#{port}")

          assert_round_trip(after_client, "Failed to round-trip key after requiring #{gem_name.inspect}")
        end
      end
    end
  end

  private

  def assert_round_trip(client, message)
    expected = SecureRandom.hex(4)
    key = "round-trip-#{expected}"
    ttl = 10 # seconds

    client.set(key, expected, ttl)

    assert_equal(expected, client.get(key), message)
  end

  def in_isolation(timeout:) # rubocop:disable Metrics
    r, w = IO.pipe

    pid = fork do
      yield
      exit!(0)
    # We rescue Exception so we can catch everything, including MiniTest::Assertion.
    rescue Exception => e # rubocop:disable Lint/RescueException
      w.write(Marshal.dump(e))
    ensure
      w.close
      exit!
    end

    begin
      Timeout.timeout(timeout) do
        _, status = Process.wait2(pid)
        w.close
        marshaled_exception = r.read
        r.close

        unless marshaled_exception.empty?
          raise begin
            Marshal.load(marshaled_exception) # rubocop:disable Security/MarshalLoad
          rescue StandardError => e
            raise <<~MESSAGE
              Failed to unmarshal error from fork with exit status #{status.exitstatus}!
              #{e.class}: #{e}
              ---MARSHALED_EXCEPTION---
              #{marshaled_exception}
              -------------------------
            MESSAGE
          end
        end

        unless status.success?
          raise "Child process exited with non-zero status #{status.exitstatus} despite piping no exception"
        end

        pass
      end
    rescue Timeout::Error
      Process.kill('KILL', pid)
      raise "Child process killed after exceeding #{timeout}s timeout"
    end
  end
end
