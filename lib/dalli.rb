# frozen_string_literal: true

require "dalli/compressor"
require "dalli/client"
require "dalli/key_manager"
require "dalli/ring"
require "dalli/protocol"
require "dalli/protocol/binary"
require 'dalli/protocol/server_config_parser'
require 'dalli/protocol/ttl_sanitizer'
require 'dalli/protocol/value_compressor'
require 'dalli/protocol/value_marshaller'
require 'dalli/protocol/value_serializer'
require 'dalli/servers_arg_normalizer'
require "dalli/socket"
require "dalli/version"
require "dalli/options"

module Dalli
  autoload :Server, "dalli/server"

  # generic error
  class DalliError < RuntimeError; end
  # socket/server communication error
  class NetworkError < DalliError; end
  # no server available/alive error
  class RingError < DalliError; end
  # application error in marshalling serialization
  class MarshalError < DalliError; end
  # application error in marshalling deserialization or decompression
  class UnmarshalError < DalliError; end
  # payload too big for memcached
  class ValueOverMaxSize < DalliError; end

  def self.logger
    @logger ||= (rails_logger || default_logger)
  end

  def self.rails_logger
    (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) ||
      (defined?(RAILS_DEFAULT_LOGGER) && RAILS_DEFAULT_LOGGER.respond_to?(:debug) && RAILS_DEFAULT_LOGGER)
  end

  def self.default_logger
    require "logger"
    l = Logger.new($stdout)
    l.level = Logger::INFO
    l
  end

  def self.logger=(logger)
    @logger = logger
  end
end
