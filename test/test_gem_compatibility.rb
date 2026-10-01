# frozen_string_literal: true

# JRuby does not support forking, so skip these tests on JRuby.
return unless Process.respond_to?(:fork)

require_relative 'helper'

# Gems that monkey-patch TCPSocket and may break connect_timeout: keyword argument.
# These are loaded in isolated forked processes to avoid affecting other tests.
# Format: { gem_name => require_path }
GEM_COMPATIBILITY_TEST_GEMS = {
  'resolv-replace' => 'resolv-replace',
  'socksify' => 'socksify'
}.freeze

describe 'gem compatibility' do
  GEM_COMPATIBILITY_TEST_GEMS.each do |gem_name, require_path|
    describe "with #{gem_name} gem" do
      it 'can perform basic operations after gem is required' do
        memcached(:meta, rand(21_397..21_896)) do |_, port|
          run_compatibility_test(gem_name, require_path, port)
        end
      end
    end
  end

  private

  def run_compatibility_test(gem_name, require_path, port)
    read_pipe, write_pipe = IO.pipe

    pid = fork do
      read_pipe.close
      execute_compatibility_test(gem_name, require_path, port, write_pipe)
    end

    write_pipe.close
    wait_for_child(pid, read_pipe, timeout: 15)
  end

  def execute_compatibility_test(gem_name, require_path, port, write_pipe)
    # Verify operations work before requiring the gem
    before_client = Dalli::Client.new("127.0.0.1:#{port}")

    assert_round_trip(before_client, "before requiring #{gem_name}")

    # Require the gem (this may monkey-patch TCPSocket)
    require require_path

    # Verify operations still work after requiring the gem
    after_client = Dalli::Client.new("127.0.0.1:#{port}")

    assert_round_trip(after_client, "after requiring #{gem_name}")

    write_pipe.write('OK')
  rescue Exception => e # rubocop:disable Lint/RescueException
    write_pipe.write(Marshal.dump(e))
  ensure
    write_pipe.close
    exit!(0)
  end

  def wait_for_child(pid, read_pipe, timeout:)
    Timeout.timeout(timeout) do
      Process.wait(pid)
      handle_child_result(read_pipe.read)
    end
  rescue Timeout::Error
    Process.kill('KILL', pid)
    Process.wait(pid)

    flunk "Child process timed out after #{timeout}s"
  ensure
    read_pipe.close
  end

  def handle_child_result(result)
    if result == 'OK'
      pass
    elsif result.empty?
      flunk "Child process exited without result (status: #{$CHILD_STATUS.exitstatus})"
    else
      raise Marshal.load(result) # rubocop:disable Security/MarshalLoad
    end
  end

  def assert_round_trip(client, context)
    key = "compat-test-#{SecureRandom.hex(4)}"
    expected = SecureRandom.hex(8)
    ttl = 60

    client.set(key, expected, ttl)
    actual = client.get(key)

    assert_equal expected, actual, "Round-trip failed #{context}"
  end
end
