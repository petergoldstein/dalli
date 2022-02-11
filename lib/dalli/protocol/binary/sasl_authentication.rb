# frozen_string_literal: true

module Dalli
  module Protocol
    class Binary
      ##
      # Code to support SASL authentication
      ##
      module SaslAuthentication
        def perform_auth_negotiation
          write(RequestFormatter.standard_request(opkey: :auth_negotiation))

          status, content = response_processor.auth_response
          return [status, []] if content.nil?

          # Substitute spaces for the \x00 returned by
          # memcached as a separator for easier
          content&.tr!("\u0000", ' ')
          mechanisms = content&.split
          [status, mechanisms]
        end

        PLAIN_AUTH = 'PLAIN'

        def supported_mechanisms!(mechanisms)
          unless mechanisms.include?(PLAIN_AUTH)
            raise NotImplementedError,
                  'Dalli only supports the PLAIN authentication mechanism'
          end
          [PLAIN_AUTH]
        end

        def authenticate_with_plain
          write(RequestFormatter.standard_request(opkey: :auth_request,
                                                  key: PLAIN_AUTH,
                                                  value: "\x0#{username}\x0#{password}"))
          @response_processor.auth_response
        end

        def authenticate_connection
          Dalli.logger.info { "Dalli/SASL authenticating as #{username}" }

          status, mechanisms = perform_auth_negotiation
          return Dalli.logger.debug('Authentication not required/supported by server') if status == 0x81

          supported_mechanisms!(mechanisms)
          status, content = authenticate_with_plain

          return Dalli.logger.info("Dalli/SASL: #{content}") if status.zero?

          raise Dalli::DalliError, "Error authenticating: 0x#{status.to_s(16)}" unless status == 0x21

          raise NotImplementedError, 'No two-step authentication mechanisms supported'
          # (step, msg) = sasl.receive('challenge', content)
          # raise Dalli::NetworkError, "Authentication failed" if sasl.failed? || step != 'response'
        end
      end
    end
  end
end
