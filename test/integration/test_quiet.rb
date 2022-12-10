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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.set(key, value)
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.add(key, value)

            # Should handle error case without error or unexpected behavior
            assert_nil dc.add(existing, value)
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.replace(key, value)

            # Should handle error case without error or unexpected behavior
            assert_nil dc.replace(nonexistent, value)
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.delete(existing)

            # Should handle error case without error or unexpected behavior
            assert_nil dc.delete(key)
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.append(key, 'abc')
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.prepend(key, 'abc')
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be nil
            assert_nil dc.incr(key, incr)
          end

          refute Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

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

          refute Thread.current[Dalli::QUIET]
          dc.quiet do
            assert Thread.current[Dalli::QUIET]

            # Response should be a non-empty array of nils
            arr = dc.flush(90)

            assert_equal 2, arr.size
            assert arr.all?(&:nil?)
          end

          refute Thread.current[Dalli::QUIET]
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

          refute Thread.current[Dalli::QUIET]
          dc.multi do
            assert Thread.current[Dalli::QUIET]
            dc.delete('non_existent_key')
          end

          refute Thread.current[Dalli::QUIET]
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

          refute Thread.current[Dalli::QUIET]
          dc.multi do
            assert Thread.current[Dalli::QUIET]
            assert_raises Dalli::NotPermittedMultiOpError do
              dc.get('a')
            end
          end

          refute Thread.current[Dalli::QUIET]
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
