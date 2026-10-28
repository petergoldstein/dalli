# frozen_string_literal: true

require_relative '../helper'

describe 'Quiet behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'supports the use of set in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.set(key, value)
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_equal value, dc.get(key)
        end
      end

      it 'supports the use of add in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          existing = SecureRandom.hex(4)
          oldvalue = SecureRandom.hex(3)
          value = SecureRandom.hex(3)
          dc.set(existing, oldvalue)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.add(key, value)

            # Should handle error case without error or unexpected behavior
            assert_nil dc.add(existing, value)
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_equal value, dc.get(key)
          assert_equal oldvalue, dc.get(existing)
        end
      end

      it 'supports the use of replace in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          nonexistent = SecureRandom.hex(4)
          oldvalue = SecureRandom.hex(3)
          value = SecureRandom.hex(3)
          dc.set(key, oldvalue)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.replace(key, value)

            # Should handle error case without error or unexpected behavior
            assert_nil dc.replace(nonexistent, value)
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_equal value, dc.get(key)
          assert_nil dc.get(nonexistent)
        end
      end

      it 'supports the use of delete in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          existing = SecureRandom.hex(4)
          value = SecureRandom.hex(3)
          dc.set(existing, value)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.delete(existing)

            # Should handle error case without error or unexpected behavior
            assert_nil dc.delete(key)
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_nil dc.get(existing)
          assert_nil dc.get(key)
        end
      end

      it 'supports the use of append in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)
          dc.set(key, value, 90, raw: true)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.append(key, 'abc')
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_equal "#{value}abc", dc.get(key)
        end
      end

      it 'supports the use of prepend in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          value = SecureRandom.hex(3)
          dc.set(key, value, 90, raw: true)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.prepend(key, 'abc')
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_equal "abc#{value}", dc.get(key)
        end
      end

      it 'supports the use of incr in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          value = 546
          incr = 134
          dc.set(key, value, 90, raw: true)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.incr(key, incr)
          end

          refute_operator Thread.current, :[], Dalli::QUIET

          assert_equal 680, dc.get(key).to_i
        end
      end

      it 'supports the use of decr in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          key = SecureRandom.hex(3)
          value = 546
          incr = 134
          dc.set(key, value, 90, raw: true)

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be nil
            assert_nil dc.decr(key, incr)
          end

          assert_equal 412, dc.get(key).to_i
        end
      end

      it 'supports the use of flush in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.quiet do
            assert_operator Thread.current, :[], Dalli::QUIET

            # Response should be a non-empty array of nils
            arr = dc.flush(90)

            assert_equal 2, arr.size
            assert arr.all?(&:nil?)
          end

          refute_operator Thread.current, :[], Dalli::QUIET
        end
      end

      it 'does not corrupt the underlying response buffer when a memcached error occurs in a quiet block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          dc.set('a', 'av')
          dc.set('b', 'bv')

          assert_equal 'av', dc.get('a')
          assert_equal 'bv', dc.get('b')

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.multi do
            assert_operator Thread.current, :[], Dalli::QUIET
            dc.delete('non_existent_key')
          end

          refute_operator Thread.current, :[], Dalli::QUIET
          assert_equal 'av', dc.get('a')
          assert_equal 'bv', dc.get('b')
        end
      end

      it 'raises an error if an invalid operation is used in a multi block' do
        memcached_persistent(p) do |dc|
          dc.close
          dc.flush
          dc.set('a', 'av')
          dc.set('b', 'bv')

          assert_equal 'av', dc.get('a')
          assert_equal 'bv', dc.get('b')

          refute_operator Thread.current, :[], Dalli::QUIET
          dc.multi do
            assert_operator Thread.current, :[], Dalli::QUIET
            assert_raises Dalli::NotPermittedMultiOpError do
              dc.get('a')
            end
          end

          refute_operator Thread.current, :[], Dalli::QUIET
        end
      end

      # Thread.current[] is fiber-local, so a quiet block covers only the
      # thread or fiber that opened it. Its replies come back on the
      # connection that other threads and fibers share.
      describe 'with a client shared across threads and fibers' do
        # One server, so every key shares the one connection
        def with_shared_client(protocol)
          memcached_persistent(protocol) do |_, port|
            dc = Dalli::Client.new("localhost:#{port}", protocol: protocol)
            dc.flush
            dc.set('existing', 'old')
            dc.set('k3', 'value3')
            yield dc
          end
        end

        # Starts a thread that enters a quiet block, makes a failing add
        # (memcached replies NS even to a quiet add) and any requests in the
        # block, then waits inside the block until release is pushed.
        def start_quiet_thread(client, &quiet_requests)
          entered = Queue.new
          release = Queue.new
          thread = Thread.new { run_quiet_block(client, entered, release, &quiet_requests) }
          entered.pop
          [thread, release]
        end

        def run_quiet_block(client, entered, release)
          client.quiet do
            client.add('existing', 'new')
            yield if block_given?
            entered << true
            release.pop
          end
          :finished
        end

        it 'gives another thread its own replies while a quiet block has replies pending' do
          with_shared_client(p) do |dc|
            thread, release = start_quiet_thread(dc)

            assert op_addset_succeeds(dc.set('k2', 'v2'))
            assert_equal 'value3', dc.get('k3')
            assert_equal 'v2', dc.get('k2')
            assert_nil dc.get('missing')

            release << true

            assert_equal :finished, thread.value
            assert_equal 'old', dc.get('existing')
            assert_equal 'value3', dc.get('k3')
            assert_equal 'v2', dc.get('k2')
          end
        end

        # Without the drain, binary stayed out of step after the block: the
        # block's closing noop stopped at the other thread's real reply
        it 'keeps the connection in step after the quiet block ends' do
          with_shared_client(p) do |dc|
            thread, release = start_quiet_thread(dc)
            during = begin
              dc.get('k3')
            rescue Dalli::DalliError => e
              e
            end

            release << true

            assert_equal :finished, thread.value
            assert_equal 'old', dc.get('existing')
            assert_equal 'value3', dc.get('k3')
            assert_equal 'value3', during
          end
        end

        it 'reads the replies of quiet requests made after another thread read the earlier ones' do
          with_shared_client(p) do |dc|
            paused = Queue.new
            resume = Queue.new
            thread = Thread.new do
              dc.quiet do
                dc.add('existing', 'new')
                paused << true
                resume.pop
                dc.add('existing', 'newer')
                dc.set('later', 'later-value')
                paused << true
                resume.pop
              end
            end

            paused.pop

            assert_equal 'value3', dc.get('k3')
            resume << true
            paused.pop

            assert_equal 'old', dc.get('existing')
            assert_equal 'later-value', dc.get('later')
            resume << true
            thread.join

            assert_equal 'value3', dc.get('k3')
          end
        end

        it 'returns exactly the requested keys from a get_multi in another thread' do
          with_shared_client(p) do |dc|
            keys = Array.new(20) { |i| "multi#{i}" }
            keys.each { |k| dc.set(k, "v-#{k}") }
            expected = keys.to_h { |k| [k, "v-#{k}"] }
            thread, release = start_quiet_thread(dc)

            # The block form is the pipelined get
            yielded = {}
            dc.get_multi(keys + ['missing']) { |k, v| yielded[k] = v }

            assert_equal expected, yielded
            assert_equal 'value3', dc.get('k3')

            release << true
            thread.join

            assert_equal expected, dc.get_multi(keys + ['missing'])
          end
        end

        it 'gives another thread its own replies while a quiet incr of a base64 key is pending' do
          with_shared_client(p) do |dc|
            counter = 'counter with space'
            dc.incr(counter, 1, nil, 5)
            # The counter exists, so the quiet incr applies and its add fails with NS
            thread, release = start_quiet_thread(dc) { dc.incr(counter, 1, nil, 5) }

            assert_equal 'value3', dc.get('k3')
            assert op_addset_succeeds(dc.set('k2', 'v2'))
            assert_equal 'v2', dc.get('k2')

            release << true
            thread.join

            assert_equal 7, dc.incr(counter, 1)
            assert_equal 'value3', dc.get('k3')
          end
        end

        it 'gives another fiber its own replies while a quiet block has replies pending' do
          with_shared_client(p) do |dc|
            fiber = Fiber.new do
              dc.quiet do
                dc.add('existing', 'new')
                Fiber.yield :in_quiet_block
              end
              :finished
            end

            assert_equal :in_quiet_block, fiber.resume
            refute_operator Thread.current, :[], Dalli::QUIET

            assert op_addset_succeeds(dc.set('k2', 'v2'))
            assert_equal 'value3', dc.get('k3')
            assert_equal 'v2', dc.get('k2')

            assert_equal :finished, fiber.resume
            assert_equal 'old', dc.get('existing')
            assert_equal 'value3', dc.get('k3')
          end
        end
      end

      describe 'quiet? method' do
        it 'has protocol instances that respond to quiet?' do
          memcached_persistent(p) do |dc|
            s = dc.send(:ring).servers.first

            assert_respond_to s, :quiet?
          end
        end

        it 'has protocol instances that respond to multi?' do
          memcached_persistent(p) do |dc|
            s = dc.send(:ring).servers.first

            assert_respond_to s, :multi?
          end
        end
      end
    end
  end
end
