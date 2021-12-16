# frozen_string_literal: true

require_relative '../helper'

describe 'connection pool behavior' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      it 'can masquerade as a connection pool using the with method' do
        memcached_persistent do |dc|
          dc.with { |c| c.set('some_key', 'some_value') }
          assert_equal 'some_value', dc.get('some_key')

          dc.with { |c| c.delete('some_key') }
          assert_nil dc.get('some_key')
        end
      end
    end
  end
end
