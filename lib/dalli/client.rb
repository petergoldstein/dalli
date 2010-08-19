module Dalli
  class Client
    
    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    #
    # Dalli::Client.new(['localhost:11211:10', 'cache-2:11211:5', 'cache-2:22122:5'], 
    #                   :threadsafe => false, :marshal => false)
    #
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Options:
    #   :threadsafe - ensure that only one thread is actively using a socket at a time. Default: true.
    #   :marshal - ensure that the value you store is exactly what is returned.  Otherwise you can see this:
    #        set('abc', 123)
    #        get('abc') ==> '123'  (Note you set an Integer but got back a String)
    #      Default: true.
    #
    def initialize(servers, options={})
      @ring = Dalli::Ring.new(
        Array(servers).map do |s| 
          Dalli::Server.new(s)
        end
      )
      @ring.threadsafe! unless options[:threadsafe] == false
      self.extend(Dalli::Marshal) unless options[:marshal] == false
    end
    
    #
    # The standard memcached instruction set
    #

    def get(key)
      resp = perform(:get, key)
      (!resp || resp == 'Not found') ? nil : deserialize(resp)
    end

    def get_multi(*keys)
      @ring.lock do
        keys.each do |key|
          perform(:getkq, key)
        end
        values = @ring.servers.inject({}) { |hash, s| hash.merge!(s.request(:noop)); hash }
        values.inject(values) { |memo, (k,v)| memo[k] = deserialize(v); memo }
      end
    end
    
    def set(key, value, ttl=0)
      perform(:set, key, serialize(value), ttl)
    end
    
    def add(key, value, ttl=0)
      perform(:add, key, serialize(value), ttl)
    end

    def replace(key, value, ttl=0)
      perform(:replace, key, serialize(value), ttl)
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

    def close
      @ring.servers.map { |s| s.close }
    end

    private

    def serialize(value)
      value.to_s
    end
    
    def deserialize(value)
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