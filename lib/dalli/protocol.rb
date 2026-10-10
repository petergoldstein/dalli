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

    # SSL errors during the handshake or during read/write operations count as
    # a failed request: they trigger reconnection and, after
    # socket_max_failures, mark the server down.
    SSL_ERRORS =
      if defined?(OpenSSL::SSL::SSLError)
        [OpenSSL::SSL::SSLError]
      else
        []
      end
  end
end
