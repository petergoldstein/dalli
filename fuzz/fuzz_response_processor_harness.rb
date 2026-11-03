# frozen_string_literal: true

require_relative 'fuzz_helper'
require 'ruzzy'

# The reply to one request, read line by line as ConnectionManager reads it.
# The first byte picks the request the reply answers.
OPERATIONS = [
  [:meta_get_with_value, {}],
  [:meta_get_with_value, { cache_nils: true }],
  [:meta_get_with_value, { raw: true }],
  [:meta_get_with_value_and_cas, {}],
  [:meta_get_without_value, {}],
  [:meta_get_with_metadata, { cache_nils: true, return_hit_status: true, return_last_access: true,
                              return_ttl_remaining: true }],
  [:meta_set_with_cas, {}],
  [:meta_set_append_prepend, {}],
  [:meta_delete, {}],
  [:decr_incr, {}],
  [:stats, {}],
  [:version, {}],
  [:flush, {}],
  [:reset, {}],
  [:consume_all_responses_until_mn, {}],
  [:pipelined_delete_non_deletions, {}]
].freeze

MARSHALLER = DalliFuzz.value_marshaller

test_one_input = lambda do |data|
  return 0 if data.empty?

  method, options = OPERATIONS[data.getbyte(0) % OPERATIONS.size]
  connection = DalliFuzz::FakeConnection.new(data.byteslice(1..))
  processor = Dalli::Protocol::Meta::ResponseProcessor.new(connection, MARSHALLER)
  DalliFuzz.run { processor.public_send(method, **options) }
end

Ruzzy.fuzz(test_one_input)
