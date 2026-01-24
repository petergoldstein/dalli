# frozen_string_literal: true

module Dalli
  ##
  # Handles deprecation warnings for protocol and authentication features
  # that will be removed in Dalli 5.0.
  ##
  module ProtocolDeprecations
    BINARY_PROTOCOL_DEPRECATION_MESSAGE = <<~MSG.chomp
      [DEPRECATION] The binary protocol is deprecated and will be removed in Dalli 5.0. \
      Please use `protocol: :meta` instead. The meta protocol requires memcached 1.6+. \
      See https://github.com/petergoldstein/dalli for migration details.
    MSG

    SASL_AUTH_DEPRECATION_MESSAGE = <<~MSG.chomp
      [DEPRECATION] SASL authentication is deprecated and will be removed in Dalli 5.0. \
      SASL is only supported by the binary protocol, which is being removed. \
      Consider using network-level security (firewall rules, VPN) or memcached's TLS support instead.
    MSG

    private

    def emit_deprecation_warnings
      emit_binary_protocol_deprecation_warning
      emit_sasl_auth_deprecation_warning
    end

    def emit_binary_protocol_deprecation_warning
      protocol = @options[:protocol]
      # Binary is used when protocol is nil, :binary, or 'binary'
      return if protocol.to_s == 'meta'

      warn BINARY_PROTOCOL_DEPRECATION_MESSAGE
      Dalli.logger.warn(BINARY_PROTOCOL_DEPRECATION_MESSAGE)
    end

    def emit_sasl_auth_deprecation_warning
      username = @options[:username] || ENV.fetch('MEMCACHE_USERNAME', nil)
      return unless username

      warn SASL_AUTH_DEPRECATION_MESSAGE
      Dalli.logger.warn(SASL_AUTH_DEPRECATION_MESSAGE)
    end
  end
end
