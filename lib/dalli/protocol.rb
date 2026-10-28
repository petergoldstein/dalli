# frozen_string_literal: true

require 'openssl'
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

    # SSL errors during the TLS handshake count as a failed request: they
    # trigger reconnection and, after socket_max_failures, mark the server
    # down. openssl is required above because this file loads before
    # dalli/socket, so OpenSSL may not be defined yet.
    SSL_ERRORS = [OpenSSL::SSL::SSLError].freeze
  end
end
