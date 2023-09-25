# frozen_string_literal: true

require 'timeout'

module Dalli
  module Protocol
    # Preserved for backwards compatibility.  Should be removed in 4.0
    NOT_FOUND = ::Dalli::NOT_FOUND

    # Ruby 3.2 raises IO::TimeoutError on blocking reads/writes, but
    # it is not defined in earlier Ruby versions.
    TIMEOUT_ERRORS =
      if defined?(IO::TimeoutError)
        [Timeout::Error, IO::TimeoutError]
      else
        [Timeout::Error]
      end
  end
end
