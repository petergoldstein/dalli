require 'dalli/client'
require 'dalli/ring'
require 'dalli/server'
require 'dalli/version'

require 'logger'

module Dalli
  # socket communication error
  class NetworkError < RuntimeError; end
  class ServerError < RuntimeError; end

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