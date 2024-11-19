# frozen_string_literal: true

require_relative '../helper'

describe 'Pipelined Get' do
  it 'supports pipelined set' do
    memcached_persistent do |dc|
      dc.close
      dc.flush
    end
    toxi_memcached_persistent do |dc|
      dc.close
      dc.flush

      resp = dc.get_multi(%w[a b c d e f])

      assert_empty(resp)

      pairs = { 'a' => 'foo', 'b' => 123, 'c' => 'raw' }
      dc.set_multi(pairs, 60, raw: true)

      # Invocation without block
      resp = dc.get_multi(%w[a b c d e f])
      expected_resp = { 'a' => 'foo', 'b' => '123', 'c' => 'raw' }

      assert_equal(expected_resp, resp)
    end
  end

  it 'pipelined set handles network errors' do
    memcached_persistent do |dc|
      dc.close
      dc.flush
    end
    toxi_memcached_persistent do |dc|
      dc.close
      dc.flush

      resp = dc.get_multi(%w[a b c d e f])

      assert_empty(resp)

      pairs = { 'a' => 'foo', 'b' => 123, 'c' => 'raw' }
      Toxiproxy[/dalli_memcached/].down do
        dc.set_multi(pairs, 60, raw: true)
      end
      # Invocation without block
      resp = dc.get_multi(%w[a b c d e f])
      expected_resp = {}

      assert_equal(expected_resp, resp)
    end
  end
end
