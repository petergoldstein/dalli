# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::Base do
  describe 'raw_mode?' do
    it 'returns false when client is not in raw mode' do
      server = Dalli::Protocol::Meta.new('localhost:11211', {})

      refute_predicate server, :raw_mode?
    end

    it 'returns true when client is in raw mode' do
      server = Dalli::Protocol::Meta.new('localhost:11211', { raw: true })

      assert_predicate server, :raw_mode?
    end
  end
end
