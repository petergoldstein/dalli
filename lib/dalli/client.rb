module Dalli
  class Client
    
    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    # <pre>
    # Dalli::Client.new(['localhost:11211:10', 'cache-2.example.com:11211:5', '192.168.0.1:22122:5'], 
    #                   :threadsafe => false, :marshal => false)
    # </pre>
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Both weight and port are optional.
    #
    # Options:
    #   :failover - if a server is down, store the value on another server.  Default: true.
    #   :threadsafe - ensure that only one thread is actively using a socket at a time. Default: true.
    #   :marshal - ensure that the value you store is exactly what is returned.  Otherwise you can see this:
    #        set('abc', 123)
    #        get('abc') ==> '123'  (Note you set an Integer but got back a String)
    #      Default: true.
    #
    def initialize(servers=nil, options={})
      @ring = Dalli::Ring.new(
        Array(env_servers || servers).map do |s| 
          Dalli::Server.new(s)
        end, options
      )
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
        keys.flatten.each do |key|
          perform(:getkq, key)
        end
        values = @ring.servers.inject({}) { |hash, s| hash.merge!(s.request(:noop)); hash }
        values.inject(values) { |memo, (k,v)| memo[k] = deserialize(v); memo }
      end
    end

    def fetch(key, ttl=0)
      val = get(key)
      if val.nil? && block_given?
        val = yield
        add(key, val, ttl)
      end
      val
    end

    def cas(key, ttl=0, &block)
      (value, cas) = perform(:cas, key)
      value = (!value || value == 'Not found') ? nil : deserialize(value)
      if value
        newvalue = block.call(value)
        perform(:add, key, serialize(newvalue), ttl, cas)
      end
    end

    def set(key, value, ttl=0)
      perform(:set, key, serialize(value), ttl)
    end
    
    def add(key, value, ttl=0)
      perform(:add, key, serialize(value), ttl, 0)
    end

    def replace(key, value, ttl=0)
      perform(:replace, key, serialize(value), ttl)
    end

    def delete(key)
      perform(:delete, key)
    end

    def append(key, value)
      perform(:append, key, value.to_s)
    end

    def prepend(key, value)
      perform(:prepend, key, value.to_s)
    end

    def flush(delay=0)
      time = -delay
      @ring.servers.map { |s| s.request(:flush, time += delay) }
    end

    def flush_all
      flush(0)
    end

    ##
    # Incr adds the given amount to the counter on the memcached server.
    # Amt must be a positive value.
    # 
    # memcached counters are unsigned and cannot hold negative values.  Calling
    # decr on a counter which is 0 will just return 0.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    def incr(key, amt, ttl=0, default=nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      perform(:incr, key, amt, ttl, default)
    end

    ##
    # Decr subtracts the given amount from the counter on the memcached server.
    # Amt must be a positive value.
    # 
    # memcached counters are unsigned and cannot hold negative values.  Calling
    # decr on a counter which is 0 will just return 0.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    def decr(key, amt, ttl=0, default=nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      perform(:decr, key, amt, ttl, default)
    end

    def stats
      @ring.servers.inject({}) { |memo, s| memo["#{s.hostname}:#{s.port}"] = s.request(:stats); memo }
    end

    def close
      @ring.servers.map { |s| s.close }
      @ring = nil
    end

    private

    def serialize(value)
      value.to_s
    end
    
    def deserialize(value)
      value
    end

    def env_servers
      ENV['MEMCACHE_SERVERS'] ? ENV['MEMCACHE_SERVERS'].split(',') : nil
    end

    # Chokepoint method for instrumentation
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