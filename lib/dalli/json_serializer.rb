# frozen_string_literal: true

require 'json'

module Dalli
  ##
  # A serializer that stores values as JSON and never creates Ruby objects
  # from what it reads.
  #
  # Passing the JSON module itself as the serializer (serializer: JSON) reads
  # values back with JSON.load, which on json gem versions before 3.0 honors
  # "json_class" and instantiates other classes when the json gem's additions
  # are loaded. This serializer reads with JSON.parse, so a value written to
  # memcached by someone else can only come back as plain hashes, arrays,
  # strings, numbers, booleans and nil.
  #
  #   Dalli::Client.new(servers, serializer: Dalli::JSONSerializer)
  ##
  module JSONSerializer
    def self.dump(value)
      JSON.generate(value)
    end

    def self.load(data)
      JSON.parse(data)
    end
  end
end
