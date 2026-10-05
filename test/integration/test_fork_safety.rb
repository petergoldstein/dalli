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

describe 'Fork safety of the inherited connection' do
  next unless Process.respond_to?(:fork)

  MemcachedManager.supported_protocols.each do |protocol|
    describe "using the #{protocol} protocol" do
      # A forked child that closes the client must not send requests the
      # parent had written but not yet flushed, such as quiet writes that
      # wait for the end of the block.
      it 'does not resend buffered quiet writes when a forked child closes the client' do
        memcached_persistent(protocol) do |dc, _port|
          dc.set('fork_counter', '0', 0, raw: true)

          dc.quiet do
            dc.incr('fork_counter', 1)
            pid = fork do
              dc.close
              exit!(0)
            end
            Process.wait(pid)
          end

          assert_equal '1', dc.get('fork_counter', raw: true)
        end
      end

      # Closing the TLS socket in the child would send close_notify on the
      # session the parent is still using.
      it 'leaves the parent TLS session usable after a forked child closes the client' do
        # A fixed port: the helper's default random range is shared with
        # tests that start memcached without TLS
        memcached_ssl_persistent(protocol, 21_951) do |dc, _port|
          dc.set('tls_fork_key', 'parent_value')
          server = dc.instance_variable_get(:@ring).servers.first
          parent_sock = server.sock

          pid = fork do
            dc.close
            exit!(0)
          end
          Process.wait(pid)
          # Give memcached time to act on a close_notify from the child, which
          # would close the shared connection. Nothing arrives when the child
          # leaves the TLS session alone.
          parent_sock.to_io.wait_readable(0.5)

          with_nil_logger do
            assert_equal 'parent_value', dc.get('tls_fork_key')
          end
          # Same connection: the get didn't have to reconnect and retry
          assert_same parent_sock, server.sock
        end
      end
    end
  end
end
