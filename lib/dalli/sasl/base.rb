module SASL
  class Preferences
    def username
      ENV['MEMCACHE_USERNAME'].strip
    end

    def password
      ENV['MEMCACHE_PASSWORD'].strip
    end
  end

  def SASL.new
    DigestMD5.new(Preferences.new)
  end

  ##
  # Common functions for mechanisms
  #
  # Mechanisms implement handling of methods start and receive. They
  # return: [message_name, content] or nil where message_name is
  # either 'auth' or 'response' and content is either a string which
  # may transmitted encoded as Base64 or nil.
  class Mechanism
    attr_reader :preferences

    def initialize(preferences)
      @preferences = preferences
      @state = nil
    end

    def success?
      @state == :success
    end
    def failure?
      @state == :failure
    end

    def start
      raise NotImplementedError
    end

    def receive(message_name, content)
      case message_name
      when 'success'
        @state = :success
      when 'failure'
        @state = :failure
      end
      nil
    end
  end
end
