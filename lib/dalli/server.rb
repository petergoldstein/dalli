# frozen_string_literal: true

module Dalli
  warn "Dalli::Server is deprecated, use Dalli::Protocol::Binary instead"
  Server = Protocol::Binary
end
