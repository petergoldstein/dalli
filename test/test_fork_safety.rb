# frozen_string_literal: true

require_relative 'helper'

class TestForkSafety < Minitest::Test
  include Memcached::Helper

  def setup
    skip('Fork unavailable') unless Process.respond_to?(:fork)
  end

  MemcachedManager.supported_protocols.each do |protocol|
    define_method "test_fork_safety_#{protocol}" do
      memcached_persistent(protocol) do |dc, _port|
        # Set initial value
        dc.set('key', 'foo')

        assert_equal 'foo', dc.get('key')

        pid = fork do
          run_child_process(dc)
          exit!(0)
        end

        run_parent_process(dc)
        _, status = Process.wait2(pid)

        assert_predicate(status, :success?)

        # Verify we can still perform operations in parent
        dc.get('key') # Just ensure this doesn't raise an error

        assert_kind_of String, dc.get('key'), 'Expected a string value from memcached'
      end
    end
  end

  private

  def run_child_process(dalli_client)
    # Child process should detect fork and reconnect automatically
    100.times do |i|
      # Should work without errors due to auto-reconnection
      dalli_client.set('key', "child_#{i}")
      sleep(0.01) # Add a small delay to prevent racing too fast
    end
  end

  def run_parent_process(dalli_client)
    # Parent process should continue to work
    100.times do |_i|
      # Basic operation to ensure connection still works
      begin
        dalli_client.get('foo')
      rescue StandardError
        nil
      end
      sleep(0.01) # Add a small delay
    end
  end
end
