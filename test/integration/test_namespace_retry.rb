# frozen_string_literal: true

require_relative '../helper'

# A request retried after a transient network error must go to the same key.
# (On this line single-key operations re-read the key from their arguments on
# each retry; get_with_metadata and fetch_with_lock didn't.)
# The retry used to re-run with the already-namespaced key, applying the
# namespace twice ("app:x" became "app:app:x"), so a retried read returned a
# different key's value and a retried write overwrote a different key.
describe 'Retrying a request with a namespace' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      # Fails the first request the server sees with a retryable error, then
      # behaves normally, recording the keys each attempt asked for.
      def with_one_transient_failure(client)
        server = client.send(:ring).servers.first
        original = server.method(:request)
        seen = []
        failed = false
        flaky = lambda do |opkey, *args, **kwargs, &blk|
          seen << [opkey, args.first]
          unless failed
            failed = true
            raise Dalli::RetryableNetworkError, 'transient blip'
          end

          original.call(opkey, *args, **kwargs, &blk)
        end
        server.stub(:request, flaky) { yield seen }
      end

      def plain_client(port, protocol) = Dalli::Client.new("127.0.0.1:#{port}", protocol: protocol)

      def namespaced_client(port, protocol)
        Dalli::Client.new("127.0.0.1:#{port}", namespace: 'app', protocol: protocol)
      end

      it 'reads the same key on the retry of a single-key read' do
        memcached_persistent(p) do |_, port|
          plain = plain_client(port, p)
          plain.flush
          plain.set('app:x', 'right', 0, raw: true)
          plain.set('app:app:x', 'wrong', 0, raw: true)
          dc = namespaced_client(port, p)

          with_one_transient_failure(dc) do |seen|
            assert_equal 'right', dc.get('x', raw: true)
            assert_equal 2, seen.size
            assert_equal seen[0][1], seen[1][1]
          end
        end
      end

      it 'writes the same key on the retry of a single-key write' do
        memcached_persistent(p) do |_, port|
          plain = plain_client(port, p)
          plain.flush
          dc = namespaced_client(port, p)

          with_one_transient_failure(dc) { dc.set('x', 'value', 0, raw: true) }

          assert_equal 'value', plain.get('app:x', raw: true)
          assert_nil plain.get('app:app:x', raw: true)
        end
      end

      it 'reads the same key on the retry of get_with_metadata and fetch_with_lock' do
        skip 'get_with_metadata requires the meta protocol' unless p == :meta

        memcached_persistent(p) do |_, port|
          plain = plain_client(port, p)
          plain.flush
          plain.set('app:x', 'right', 0, raw: true)
          plain.set('app:app:x', 'wrong', 0, raw: true)
          dc = namespaced_client(port, p)

          with_one_transient_failure(dc) do
            assert_equal 'right', dc.get_with_metadata('x', raw: true)[:value]
          end
          with_one_transient_failure(dc) do
            assert_equal('right', dc.fetch_with_lock('x', req_options: { raw: true }) { 'computed' })
          end
        end
      end
    end
  end
end
