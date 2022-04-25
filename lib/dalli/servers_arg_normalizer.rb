# frozen_string_literal: true

module Dalli
  ##
  # This module contains methods for validating and normalizing the servers
  # argument passed to the client.  This argument can be nil, a string, or
  # an array of strings.  Each string value in the argument can represent
  # a single server or a comma separated list of servers.
  #
  # If nil, it falls back to the values of ENV['MEMCACHE_SERVERS'] if the latter is
  # defined.  If that environment value is not defined, a default of '127.0.0.1:11211'
  # is used.
  #
  # A server config string can take one of three forms:
  #   * A colon separated string of (host, port, weight) where both port and
  #     weight are optional (e.g. 'localhost', 'abc.com:12345', 'example.org:22222:3')
  #   * A colon separated string of (UNIX socket, weight) where the weight is optional
  #     (e.g. '/var/run/memcached/socket', '/tmp/xyz:3') (not supported on Windows)
  #   * A URI with a 'memcached' protocol, which will typically include a username/password
  #
  # The methods in this module do not validate the format of individual server strings, but
  # rather normalize the argument into a compact array, wherein each array entry corresponds
  # to a single server config string.  If that normalization is not possible, then an
  # ArgumentError is thrown.
  ##
  module ServersArgNormalizer
    ENV_VAR_NAME = 'MEMCACHE_SERVERS'
    DEFAULT_SERVERS = ['127.0.0.1:11211'].freeze

    ##
    # Normalizes the argument into an array of servers.
    # If the argument is a string, or an array containing strings, it's expected that the URIs are comma separated e.g.
    # "memcache1.example.com:11211,memcache2.example.com:11211,memcache3.example.com:11211"
    def self.normalize_servers(arg)
      arg = apply_defaults(arg)
      validate_type(arg)
      Array(arg).flat_map { |s| s.split(',') }.reject(&:empty?)
    end

    def self.apply_defaults(arg)
      return arg unless arg.nil?

      ENV.fetch(ENV_VAR_NAME, nil) || DEFAULT_SERVERS
    end

    def self.validate_type(arg)
      return if arg.is_a?(String)
      return if arg.is_a?(Array) && arg.all?(String)

      raise ArgumentError,
            'An explicit servers argument must be a comma separated string or an array containing strings.'
    end
  end
end
