# frozen_string_literal: true

module Dalli # rubocop:disable Style/Documentation
  warn 'Dalli::Server is deprecated, use Dalli::Protocol::Meta instead'
  Server = Protocol::Meta
end
