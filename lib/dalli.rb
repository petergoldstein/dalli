require 'dalli/client'
require 'dalli/ring'
require 'dalli/server'
require 'dalli/socket'
require 'dalli/version'
require 'dalli/options'

unless ''.respond_to?(:bytesize)
  class String
    alias_method :bytesize, :size
  end
end

module Dalli
  # generic error
  class DalliError < RuntimeError; end
  # socket/server communication error
  class NetworkError < DalliError; end
  # no server available/alive error
  class RingError < DalliError; end

  def self.logger
    @logger ||= (rails_logger || default_logger)
  end

  def self.rails_logger
    (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) ||
    (defined?(RAILS_DEFAULT_LOGGER) && RAILS_DEFAULT_LOGGER.respond_to?(:debug) && RAILS_DEFAULT_LOGGER)
  end

  def self.default_logger
    require 'logger'
    l = Logger.new(STDOUT)
    l.level = Logger::INFO
    l
  end

  def self.logger=(logger)
    @logger = logger
  end
end
