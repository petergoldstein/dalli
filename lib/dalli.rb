require 'dalli/client'
require 'dalli/ring'
require 'dalli/server'
require 'dalli/version'

module Dalli
  class NetworkError < RuntimeError; end
end