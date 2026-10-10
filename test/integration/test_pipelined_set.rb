# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Set' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'single-server set_multi fast path' do
        it 'sets multiple key-value pairs' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            hash = { 'a' => 'foo', 'b' => 123, 'c' => %w[x y z] }
            dc.set_multi(hash)

            assert_equal 'foo', dc.get('a')
            assert_equal 123, dc.get('b')
            assert_equal %w[x y z], dc.get('c')
          end
        end

        it 'sets with custom TTL' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            dc.set_multi({ 'ttl1' => 'val1', 'ttl2' => 'val2' }, 300)

            assert_equal 'val1', dc.get('ttl1')
            assert_equal 'val2', dc.get('ttl2')
          end
        end

        it 'sets with raw mode' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port, raw: true)
            dc.flush

            dc.set_multi({ 'r1' => 'raw_val1', 'r2' => 'raw_val2' }, 300)

            assert_equal 'raw_val1', dc.get('r1')
            assert_equal 'raw_val2', dc.get('r2')
          end
        end

        it 'handles empty hash' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.set_multi({})
          end
        end

        it 'handles large batch' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            hash = {}
            100.times { |i| hash["bulk_#{i}"] = "value_#{i}" }
            dc.set_multi(hash)

            assert_equal 'value_0', dc.get('bulk_0')
            assert_equal 'value_99', dc.get('bulk_99')
          end
        end

        it 'works with get_multi round-trip' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            hash = { 'rt1' => 'v1', 'rt2' => 'v2', 'rt3' => 'v3' }
            dc.set_multi(hash)
            result = dc.get_multi(%w[rt1 rt2 rt3 rt4])

            assert_equal hash, result
          end
        end

        it 'retries on a transient (retryable) network error and completes the write' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            server = dc.send(:ring).servers.first
            original_request = server.method(:request)
            attempts = 0
            flaky_request = lambda do |opkey, *args|
              if opkey == :write_multi_req
                attempts += 1
                raise Dalli::RetryableNetworkError, 'transient blip' if attempts == 1
              end

              original_request.call(opkey, *args)
            end

            server.stub(:request, flaky_request) do
              dc.set_multi({ 'x' => 'v' })
            end

            assert_equal 2, attempts
            assert_equal 'v', dc.get('x')
          end
        end

        it 'raises Dalli::NetworkError on a terminal (non-retryable) network error' do
          memcached_persistent(p) do |_, port|
            dc = single_server_client(port)
            dc.flush

            server = dc.send(:ring).servers.first
            failing_request = lambda do |opkey, *args|
              raise Dalli::NetworkError, 'localhost is down' if opkey == :write_multi_req

              raise "unexpected request: #{opkey}, #{args.inspect}"
            end

            server.stub(:request, failing_request) do
              assert_raises(Dalli::NetworkError) { dc.set_multi({ 'x' => 'v' }) }
            end
          end
        end
      end

      # A value that can't be marshalled, or is over value_max_bytes, must not
      # cost the other keys in the batch: every good key is stored, the bad key
      # is skipped, and the first such error is raised once the batch is done.
      # Single- and multi-server set_multi follow the same contract.
      describe 'with a value that cannot be stored' do
        {
          'an unmarshallable value' => [Dalli::MarshalError, proc {}],
          'a value over value_max_bytes' => [Dalli::ValueOverMaxSize, 'x' * 2048]
        }.each do |label, (error_class, bad_value)|
          it "stores every good key and raises for #{label} on a single server" do
            memcached_persistent(p) do |_, port|
              dc = single_server_client(port, value_max_bytes: 1024)
              dc.flush

              good = {}
              20.times { |i| good["good_#{i}"] = "value_#{i}" }

              with_nil_logger do
                assert_raises(error_class) { dc.set_multi(good.merge('bad' => bad_value)) }
              end

              assert_equal good, dc.get_multi(good.keys)
              assert_nil dc.get('bad')
            end
          end

          it "logs keys but not values for #{label} on a single server" do
            memcached_persistent(p) do |_, port|
              dc = single_server_client(port, value_max_bytes: 1024)
              log = StringIO.new
              old_logger = Dalli.logger
              Dalli.logger = Logger.new(log)
              begin
                assert_raises(error_class) { dc.set_multi('good_key' => 'secret_value', 'bad' => bad_value) }
              ensure
                Dalli.logger = old_logger
              end

              refute_includes log.string, 'secret_value'
              assert_includes log.string, 'good_key' if error_class == Dalli::MarshalError
            end
          end

          it "stores every good key and raises for #{label} across servers" do
            port1 = 27_611
            port2 = 27_612
            memcached(p, port1) do
              memcached(p, port2) do
                dc = Dalli::Client.new(["127.0.0.1:#{port1}", "127.0.0.1:#{port2}"], value_max_bytes: 1024)
                dc.flush

                good = {}
                20.times { |i| good["good_#{i}"] = "value_#{i}" }

                with_nil_logger do
                  assert_raises(error_class) { dc.set_multi(good.merge('bad' => bad_value)) }
                end

                assert_equal good, dc.get_multi(good.keys)
                assert_nil dc.get('bad')
              end
            end
          end
        end
      end
    end
  end
end
