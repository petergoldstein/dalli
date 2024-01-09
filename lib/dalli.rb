# frozen_string_literal: true

##
# Namespace for all Dalli code.
##
module Dalli
  autoload :Server, 'dalli/server'

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

  # operation is not permitted in a multi block
  class NotPermittedMultiOpError < DalliError; end

  # Implements the NullObject pattern to store an application-defined value for 'Key not found' responses.
  class NilObject; end # rubocop:disable Lint/EmptyClass
  NOT_FOUND = NilObject.new

  QUIET = :dalli_multi

  def self.logger
    @logger ||= rails_logger || default_logger
  end

  def self.rails_logger
    (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) ||
      (defined?(RAILS_DEFAULT_LOGGER) && RAILS_DEFAULT_LOGGER.respond_to?(:debug) && RAILS_DEFAULT_LOGGER)
  end

  def self.default_logger
    require 'logger'
    l = Logger.new($stdout)
    l.level = Logger::INFO
    l
  end

  def self.logger=(logger)
    @logger = logger
  end
end

require_relative 'dalli/version'

require_relative 'dalli/compressor'
require_relative 'dalli/client'
require_relative 'dalli/key_manager'
require_relative 'dalli/pipelined_getter'
require_relative 'dalli/ring'
require_relative 'dalli/protocol'
require_relative 'dalli/protocol/base'
require_relative 'dalli/protocol/binary'
require_relative 'dalli/protocol/connection_manager'
require_relative 'dalli/protocol/meta'
require_relative 'dalli/protocol/response_buffer'
require_relative 'dalli/protocol/server_config_parser'
require_relative 'dalli/protocol/ttl_sanitizer'
require_relative 'dalli/protocol/value_compressor'
require_relative 'dalli/protocol/value_marshaller'
require_relative 'dalli/protocol/value_serializer'
require_relative 'dalli/servers_arg_normalizer'
require_relative 'dalli/socket'
require_relative 'dalli/options'
