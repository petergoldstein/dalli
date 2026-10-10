# frozen_string_literal: true

require 'uri'

module Dalli
  module Protocol
    ##
    # Dalli::Protocol::ServerConfigParser parses a server string passed to
    # a Dalli::Protocol::Meta instance into the hostname, port, weight, and
    # socket_type.
    ##
    class ServerConfigParser
      MEMCACHED_URI_PROTOCOL = 'memcached://'

      # TODO: Revisit this, especially the IP/domain part.  Likely
      # can limit character set to LDH + '.'.  Hex digit section
      # is there to support IPv6 addresses, which need to be specified with
      # a bounding []
      SERVER_CONFIG_REGEXP = /\A(\[([\h:]+)\]|[^:]+)(?::(\d+))?(?::(\d+))?\z/

      DEFAULT_PORT = 11_211
      DEFAULT_WEIGHT = 1

      def self.parse(str)
        return parse_non_uri(str) unless str.start_with?(MEMCACHED_URI_PROTOCOL)

        parse_uri(str)
      end

      def self.parse_uri(str)
        uri = URI.parse(str)
        auth_details = {
          username: uri.user,
          password: uri.password
        }
        [uri.hostname, normalize_port(uri.port), :tcp, DEFAULT_WEIGHT, auth_details]
      end

      def self.parse_non_uri(str)
        res = deconstruct_string(str)

        hostname = normalize_host_from_match(str, res)
        if hostname.start_with?('/')
          socket_type = :unix
          port, weight = attributes_for_unix_socket(res)
        else
          socket_type = :tcp
          port, weight = attributes_for_tcp_socket(res)
        end
        [hostname, port, socket_type, weight, {}]
      end

      def self.deconstruct_string(str)
        mtch = str.match(SERVER_CONFIG_REGEXP)
        raise Dalli::DalliError, "Could not parse hostname #{str}" if mtch.nil? || mtch[1] == '[]'

        mtch
      end

      def self.attributes_for_unix_socket(res)
        # in case of unix socket, allow only setting of weight, not port
        raise Dalli::DalliError, "Could not parse hostname #{res[0]}" if res[4]

        [nil, normalize_weight(res[3], res[0])]
      end

      def self.attributes_for_tcp_socket(res)
        [normalize_port(res[3]), normalize_weight(res[4], res[0])]
      end

      def self.normalize_host_from_match(str, res)
        raise Dalli::DalliError, "Could not parse hostname #{str}" if res.nil? || res[1] == '[]'

        res[2] || res[1]
      end

      def self.normalize_port(port)
        Integer(port || DEFAULT_PORT)
      end

      # A weight below 1 gives the server no points on the ring, and if every
      # server has one the ring divides by a zero total weight.
      def self.normalize_weight(weight, str)
        value = Integer(weight || DEFAULT_WEIGHT)
        raise ArgumentError, "Server weight must be at least 1, got #{value} in #{str}" if value < 1

        value
      end
    end
  end
end
