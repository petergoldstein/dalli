require 'dalli/client'
require 'dalli/ring'
require 'dalli/server'
require 'dalli/version'
require 'dalli/options'

require 'logger'

module Dalli
  # socket communication error
  class DalliError < RuntimeError; end
  class NetworkError < DalliError; end
  class ServerError < DalliError; end

  def self.logger
    @logger ||= begin
      (defined?(Rails) && Rails.logger) ||
      (defined?(RAILS_DEFAULT_LOGGER) && RAILS_DEFAULT_LOGGER) ||
      (l = Logger.new(STDOUT); l.level = Logger::INFO; l)
    end
  end

  def self.logger=(logger)
    @logger = logger
  end
end