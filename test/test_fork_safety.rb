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
          # Child process should detect fork and reconnect automatically
          100.times do |i|
            # Should work without errors due to auto-reconnection
            dc.set('key', "child_#{i}")
            sleep(0.01) # Add a small delay to prevent racing too fast
          end
          exit!(0)
        end

        # Parent process should continue to work
        100.times do |_i|
          # Basic operation to ensure connection still works
          begin
            dc.get('foo')
          rescue StandardError
            nil
          end
          sleep(0.01) # Add a small delay
        end

        # Wait for child to finish
        _, status = Process.wait2(pid)

        assert_predicate(status, :success?)

        # Verify we can still perform operations in parent
        dc.get('key') # Just ensure this doesn't raise an error

        assert_kind_of String, dc.get('key'), 'Expected a string value from memcached'
      end
    end
  end
end
