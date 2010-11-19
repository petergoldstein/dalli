# encoding: ascii
module Dalli
  class Client
    
    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    # 
    #   Dalli::Client.new(['localhost:11211:10', 'cache-2.example.com:11211:5', '192.168.0.1:22122:5'], 
    #                   :threadsafe => true, :failover => true, :expires_in => 300)
    # 
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Both weight and port are optional.  If you pass in nil, Dalli will default to 'localhost:11211'.
    # Note that the <tt>MEMCACHE_SERVERS</tt> environment variable will override the servers parameter for use
    # in managed environments like Heroku.
    #
    # Options:
    # - :failover - if a server is down, look for and store values on another server in the ring.  Default: true.
    # - :threadsafe - ensure that only one thread is actively using a socket at a time. Default: true.
    # - :expires_in - default TTL in seconds if you do not pass TTL as a parameter to an individual operation, defaults to 0 or forever
    # - :compression - defaults to false, if true Dalli will compress values larger than 100 bytes before
    #    sending them to memcached.
    #
    def initialize(servers=nil, options={})
      @servers = env_servers || servers || 'localhost:11211'
      @options = { :expires_in => 0 }.merge(options)
    end
    
    #
    # The standard memcached instruction set
    #

    ##
    # Turn on quiet aka noreply support.
    # All relevant operations within this block with be effectively
    # pipelined as Dalli will use 'quiet' operations where possible.
    # Currently supports the set, add, replace and delete operations.
    def multi
      old, Thread.current[:dalli_multi] = Thread.current[:dalli_multi], true
      yield
    ensure
      Thread.current[:dalli_multi] = old
    end

    def get(key, options=nil)
      resp = perform(:get, key)
      (!resp || resp == 'Not found') ? nil : resp
    end

    ##
    # Fetch multiple keys efficiently.
    # Returns a hash of { 'key' => 'value', 'key2' => 'value1' }
    def get_multi(*keys)
      return {} if keys.empty?
      options = nil
      options = keys.pop if keys.last.is_a?(Hash) || keys.last.nil?
      ring.lock do
        keys.flatten.each do |key|
          perform(:getkq, key)
        end

        values = {}
        ring.servers.each do |server|
          next unless server.alive?
          begin
            server.request(:noop).each_pair do |key, value|
              values[key_without_namespace(key)] = value
            end
          rescue NetworkError => e
            Dalli.logger.debug { e.message }
            Dalli.logger.debug { "results from this server will be missing" }
          end
        end
        values
      end
    end

    def fetch(key, ttl=nil, options=nil)
      ttl ||= @options[:expires_in]
      val = get(key, options)
      if val.nil? && block_given?
        val = yield
        add(key, val, ttl, options)
      end
      val
    end

    ##
    # compare and swap values using optimistic locking.
    # Fetch the existing value for key.
    # If it exists, yield the value to the block.
    # Add the block's return value as the new value for the key.
    # Add will fail if someone else changed the value.
    #
    # Returns:
    # - nil if the key did not exist.
    # - false if the value was changed by someone else.
    # - true if the value was successfully updated.
    def cas(key, ttl=nil, options=nil, &block)
      ttl ||= @options[:expires_in]
      (value, cas) = perform(:cas, key)
      value = (!value || value == 'Not found') ? nil : value
      if value
        newvalue = block.call(value)
        perform(:add, key, newvalue, ttl, cas, options)
      end
    end

    def set(key, value, ttl=nil, options=nil)
      ttl ||= @options[:expires_in]
      perform(:set, key, value, ttl, options)
    end

    ##
    # Conditionally add a key/value pair, if the key does not already exist
    # on the server.  Returns true if the operation succeeded.
    def add(key, value, ttl=nil, options=nil)
      ttl ||= @options[:expires_in]
      perform(:add, key, value, ttl, 0, options)
    end

    ##
    # Conditionally add a key/value pair, only if the key already exists
    # on the server.  Returns true if the operation succeeded.
    def replace(key, value, ttl=nil, options=nil)
      ttl ||= @options[:expires_in]
      perform(:replace, key, value, ttl, options)
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
      ring.servers.map { |s| s.request(:flush, time += delay) }
    end

    # deprecated, please use #flush.
    def flush_all(delay=0)
      flush(delay)
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
    def incr(key, amt=1, ttl=nil, default=nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      ttl ||= @options[:expires_in]
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
    def decr(key, amt=1, ttl=nil, default=nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      ttl ||= @options[:expires_in]
      perform(:decr, key, amt, ttl, default)
    end

    ##
    # Collect the stats for each server.
    # Returns a hash like { 'hostname:port' => { 'stat1' => 'value1', ... }, 'hostname2:port' => { ... } }
    def stats
      values = {}
      ring.servers.each do |server|
        values["#{server.hostname}:#{server.port}"] = server.alive? ? server.request(:stats) : nil
      end
      values
    end

    ##
    # Close our connection to each server.
    # If you perform another operation after this, the connections will be re-established.
    def close
      if @ring
        @ring.servers.map { |s| s.close }
        @ring = nil
      end
    end
    alias_method :reset, :close

    private

    def ring
      @ring ||= Dalli::Ring.new(
        Array(@servers).map do |s|
          Dalli::Server.new(s, @options)
        end, @options
      )
    end

    def env_servers
      ENV['MEMCACHE_SERVERS'] ? ENV['MEMCACHE_SERVERS'].split(',') : nil
    end

    # Chokepoint method for instrumentation
    def perform(op, key, *args)
      key = key.to_s
      validate_key(key)
      key = key_with_namespace(key)
      begin
        server = ring.server_for_key(key)
        server.request(op, key, *args)
      rescue NetworkError => e
        Dalli.logger.debug { e.message }
        Dalli.logger.debug { "retrying request with new server" }
        retry
      end
    end
    
    def validate_key(key)
      raise ArgumentError, "illegal character in key #{key}" if key.respond_to?(:ascii_only?) && !key.ascii_only?
      raise ArgumentError, "illegal character in key #{key}" if key =~ /\s/
      raise ArgumentError, "illegal character in key #{key}" if key =~ /[\x00-\x20\x80-\xFF]/
      raise ArgumentError, "key cannot be blank" if key.nil? || key.strip.size == 0
      raise ArgumentError, "key too long #{key.inspect}" if key.length > 250
    end
    
    def key_with_namespace(key)
      @options[:namespace] ? "#{@options[:namespace]}:#{key}" : key
    end

    def key_without_namespace(key)
      @options[:namespace] ? key.gsub(%r(\A#{@options[:namespace]}:), '') : key
    end
  end
end
