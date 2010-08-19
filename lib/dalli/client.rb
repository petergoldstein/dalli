module Dalli
  class Client
    
    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    #
    # Dalli::Client.new(['localhost:11211:10', 'cache-2:11211:5', 'cache-2:22122:5'], 
    #                   :threadsafe => true, :marshal => true)
    #
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Options:
    #   :threadsafe - ensure that only one thread is actively using a socket at a time. Default: false.
    #   :marshal - ensure that the value you store is exactly what is returned.  Otherwise you can see this:
    #        set('abc', 123)
    #        get('abc') ==> '123'  (Note you set an Integer but got back a String)
    #      Default: false.
    #
    def initialize(servers, options={})
      @ring = Dalli::Ring.new(
        Array(servers).map do |s| 
          Dalli::Server.new(s)
        end
      )
      @ring.threadsafe! if options[:threadsafe]
      self.extend(Dalli::Marshal) if options[:marshal]
    end
    
    #
    # The standard memcached instruction set
    #

    def get(key)
      resp = perform(:get, key)
      resp == 'Not found' ? nil : out(resp)
    end

    def get_multi(keys)

    end
    
    def set(key, value, expiry=0)
      perform(:set, key, prep(value), expiry)
    end
    
    def add(key, value, ttl=0)
      perform(:add, key, prep(value), ttl)
    end

    def replace(key, value, ttl=0)
      perform(:replace, key, prep(value), ttl)
    end

    def delete(key)
      perform(:delete, key)
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

    def flush_all
      flush(0)
    end

    def incr(key, amt)
      perform(:incr, key, amt)
    end

    def decr(key, amt)
      perform(:decr, key, amt)
    end

    def stats
      @ring.servers.inject({}) { |memo, s| memo["#{s.hostname}:#{s.port}"] = s.request(:stats); memo }
    end

    def get_multi(keys, options)
    end

    private

    def prep(value)
      value.to_s
    end
    
    def out(value)
      value
    end

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