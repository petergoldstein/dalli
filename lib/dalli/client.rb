module Dalli
  class Client
    
    def initialize(servers, options=nil)
      @ring = Dalli::Ring.new(
        Array(servers).map do |s| 
          Dalli::Server.new(s)
        end
      )
    end
    
    #
    # The standard memcached instruction set
    #

    def get(key)
      resp = perform(:get, key)
      resp == 'Not found' ? nil : resp
    end
    
    def set(key, value, expiry=0)
      perform(:set, key, value, expiry)
    end
    
    def add(key, value, ttl=0)
      perform(:add, key, value, ttl)
    end

    def replace(key, value, ttl=0)
      perform(:replace, key, value, ttl)
    end

    def delete(key)
      perform(:delete, key)
    end

    def incr(key, amt)
      perform(:incr, key, amt)
    end

    def decr(key, amt)
      perform(:decr, key, amt)
    end

    def append(key, value)
      perform(:append, key, value)
    end

    def prepend(key, value)
      perform(:prepend, key, value)
    end

    def flush(delay=0)
      time = -delay
      @ring.servers.map { |s| s.request(:flush, time += delay) }
    end

    private

    def perform(op, *args)
      key = args.first
      validate_key(key)
      server = @ring.server_for_key(key)
      server.request(op, *args)
    end
    
    def validate_key(key)
      raise ArgumentError, "illegal character in key #{key.inspect}" if key =~ /\s/
      raise ArgumentError, "key cannot be blank" if key.nil? || key.strip.size == 0
      raise ArgumentError, "key too long #{key.inspect}" if key.length > 250
    end
  end
end