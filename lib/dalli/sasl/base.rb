module SASL
  
  MECHANISMS = {
  }
  
  class Preferences
    def authzid
      nil
    end

    def realm
      raise NotImplementedError
    end

    def digest_uri
      raise NotImplementedError
    end

    def username
      ENV['MEMCACHE_USERNAME']
    end

    def has_password?
      false
    end

    def allow_plaintext?
      false
    end

    def password
      ENV['MEMCACHE_PASSWORD']
    end

    def want_anonymous?
      false
    end
  end

  def SASL.new(mechanisms)
    mechanisms.each do |mech|
      if MECHANISMS.has_key?(mech)
        x = MECHANISMS[mech]
        return x.new(mech, Preferences.new)
      end
    end

    raise NotImplementedError, "No supported mechanisms in #{mechanisms.join(',')}"
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
    attr_reader :name

    def initialize(name, preferences)
      @name = name
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
