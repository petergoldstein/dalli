# frozen_string_literal: true

require_relative '../helper'

describe 'Fork safety' do
  # Skip tests if fork is not supported (e.g., JRuby)
  next unless Process.respond_to?(:fork)

  MemcachedManager.supported_protocols.each do |protocol|
    describe "using the #{protocol} protocol" do
      it 'automatically reconnects after fork' do
        memcached_persistent(protocol) do |dc, _port|
          # Set a value before forking
          dc.set('fork_test_key', 'parent_value')

          assert_equal 'parent_value', dc.get('fork_test_key')

          # Fork a child process
          read_pipe, write_pipe = IO.pipe
          pid = fork do
            read_pipe.close

            # In the child process, we should detect the fork and reconnect
            begin
              # Simple test - set a value after fork
              dc.set('child_key', 'child_value')
              value = dc.get('child_key')

              # Write success to the pipe
              write_pipe.write("success:#{value}")
            rescue StandardError => e
              # Write error to the pipe if reconnection fails
              write_pipe.write("error:#{e.class.name}:#{e.message}")
            ensure
              write_pipe.close
              exit!(0)
            end
          end

          # In the parent process
          write_pipe.close

          # Wait for child process to finish
          Process.wait(pid)

          # Read result from pipe
          result = read_pipe.read
          read_pipe.close

          # Verify the child successfully reconnected and performed operations
          assert_match(/^success:/, result, "Child process encountered an error: #{result}")
          assert_equal 'success:child_value', result

          # Parent should still be able to work
          assert_equal 'parent_value', dc.get('fork_test_key')
        end
      end
    end
  end
end
