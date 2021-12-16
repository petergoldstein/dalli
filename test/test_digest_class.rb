# frozen_string_literal: true

require_relative 'helper'

describe 'Digest class' do
  it 'raises error with invalid digest_class' do
    assert_raises ArgumentError do
      Dalli::Client.new('foo', { expires_in: 10, digest_class: Object })
    end
  end
end
