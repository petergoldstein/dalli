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

    # SSL errors that occur during read/write operations (not during initial
    # handshake) should trigger reconnection. These indicate transient network
    # issues, not configuration problems.
    SSL_ERRORS =
      if defined?(OpenSSL::SSL::SSLError)
        [OpenSSL::SSL::SSLError]
      else
        []
      end
  end
end
