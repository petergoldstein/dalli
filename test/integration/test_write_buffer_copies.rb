# frozen_string_literal: true

require_relative '../helper'

# A string passed to Dalli belongs to the caller again once the call returns.
# Requests in a quiet block are buffered until the block ends, so the buffer
# must hold a copy: changing the string afterwards used to change the bytes
# sent, putting the stream out of step or adding commands.
describe 'Write buffer' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'sends what was passed, even if the caller changes the string afterwards' do
        memcached_persistent(p) do |dc|
          dc.flush
          dc.set('a', 'start', nil, raw: true)
          dc.set('b', 'b-orig', nil, raw: true)

          buf = +'XX'
          dc.quiet do
            dc.append('a', buf)
            buf << "\r\nms b 2 T0\r\nPW\r\n"
          end

          assert_equal 'startXX', dc.get('a', raw: true)
          assert_equal 'b-orig', dc.get('b', raw: true)
        end
      end

      it 'stores each value when one string is reused for several writes' do
        keys = %w[k1 k2 k3]
        expected = %w[value-0 value-1value-1 value-2value-2value-2]
        memcached_persistent(p) do |dc|
          dc.flush
          buf = +''
          dc.quiet do
            keys.each_with_index do |k, i|
              buf.replace("value-#{i}" * (i + 1))
              dc.set(k, buf, nil, raw: true)
            end
          end

          assert_equal(expected, keys.map { |k| dc.get(k, raw: true) })
        end
      end
    end
  end
end
