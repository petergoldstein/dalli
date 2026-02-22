# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Delete' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'single-server delete_multi fast path' do
        it 'deletes multiple keys' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('d1', 'v1')
            dc.set('d2', 'v2')
            dc.set('d3', 'v3')

            assert_equal 'v1', dc.get('d1')

            dc.delete_multi(%w[d1 d2 d3])

            assert_nil dc.get('d1')
            assert_nil dc.get('d2')
            assert_nil dc.get('d3')
          end
        end

        it 'handles empty array' do
          memcached_persistent(p) do |dc|
            dc.delete_multi([])
          end
        end

        it 'handles non-existent keys' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.delete_multi(%w[nonexistent1 nonexistent2])
          end
        end

        it 'only deletes specified keys' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('keep', 'keep_val')
            dc.set('remove', 'remove_val')

            dc.delete_multi(['remove'])

            assert_equal 'keep_val', dc.get('keep')
            assert_nil dc.get('remove')
          end
        end

        it 'handles Unicode and space keys' do
          memcached_persistent(p) do |dc|
            dc.flush

            dc.set('contains space', 'space_val')
            dc.set('ƒ©åÍÎ', 'unicode_val')

            dc.delete_multi(['contains space', 'ƒ©åÍÎ'])

            assert_nil dc.get('contains space')
            assert_nil dc.get('ƒ©åÍÎ')
          end
        end

        it 'handles large batch' do
          memcached_persistent(p) do |dc|
            dc.flush

            keys = []
            100.times do |i|
              key = "del_bulk_#{i}"
              dc.set(key, "val_#{i}")
              keys << key
            end

            dc.delete_multi(keys)

            assert_nil dc.get('del_bulk_0')
            assert_nil dc.get('del_bulk_99')
          end
        end
      end
    end
  end
end
