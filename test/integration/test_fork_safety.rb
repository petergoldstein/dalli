# frozen_string_literal: true

require_relative '../helper'
require 'io/wait' # IO#wait_readable, for Rubies before 3.2

describe 'Fork safety of the inherited connection' do
  next unless Process.respond_to?(:fork)

  MemcachedManager.supported_protocols.each do |protocol|
    describe "using the #{protocol} protocol" do
      # A forked child that closes the client must not send requests the
      # parent had written but not yet flushed, such as quiet writes that
      # wait for the end of the block. (This line's sockets don't buffer
      # writes in Ruby, so this guards against that changing.)
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
        memcached_ssl_persistent(protocol) do |dc, _port|
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
