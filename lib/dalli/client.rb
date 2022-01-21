# frozen_string_literal: true

require 'digest/md5'
require 'set'

# encoding: ascii
module Dalli
  ##
  # Dalli::Client is the main class which developers will use to interact with
  # Memcached.
  ##
  class Client
    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    #
    #   Dalli::Client.new(['localhost:11211:10',
    #                      'cache-2.example.com:11211:5',
    #                      '192.168.0.1:22122:5',
    #                      '/var/run/memcached/socket'],
    #                     failover: true, expires_in: 300)
    #
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Both weight and port are optional.  If you pass in nil, Dalli will use the <tt>MEMCACHE_SERVERS</tt>
    # environment variable or default to 'localhost:11211' if it is not present.  Dalli also supports
    # the ability to connect to Memcached on localhost through a UNIX socket.  To use this functionality,
    # use a full pathname (beginning with a slash character '/') in place of the "host:port" pair in
    # the server configuration.
    #
    # Options:
    # - :namespace - prepend each key with this value to provide simple namespacing.
    # - :failover - if a server is down, look for and store values on another server in the ring.  Default: true.
    # - :threadsafe - ensure that only one thread is actively using a socket at a time. Default: true.
    # - :expires_in - default TTL in seconds if you do not pass TTL as a parameter to an individual operation, defaults
    #                 to 0 or forever.
    # - :compress - if true Dalli will compress values larger than compression_min_size bytes before sending them
    #               to memcached.  Default: true.
    # - :compression_min_size - the minimum size (in bytes) for which Dalli will compress values sent to Memcached.
    #                           Defaults to 4K.
    # - :serializer - defaults to Marshal
    # - :compressor - defaults to Dalli::Compressor, a Zlib-based implementation
    # - :cache_nils - defaults to false, if true Dalli will not treat cached nil values as 'not found' for
    #                 #fetch operations.
    # - :digest_class - defaults to Digest::MD5, allows you to pass in an object that responds to the hexdigest method,
    #                   useful for injecting a FIPS compliant hash object.
    # - :protocol - one of either :binary or :meta, defaulting to :binary.  This sets the protocol that Dalli uses
    #               to communicate with memcached.
    #
    def initialize(servers = nil, options = {})
      @normalized_servers = ::Dalli::ServersArgNormalizer.normalize_servers(servers)
      @options = normalize_options(options)
      @key_manager = ::Dalli::KeyManager.new(@options)
      @ring = nil
    end

    #
    # The standard memcached instruction set
    #

    ##
    # Get the value associated with the key.
    # If a value is not found, then +nil+ is returned.
    def get(key, req_options = nil)
      perform(:get, key, req_options)
    end

    ##
    # Gat (get and touch) fetch an item and simultaneously update its expiration time.
    #
    # If a value is not found, then +nil+ is returned.
    def gat(key, ttl = nil)
      perform(:gat, key, ttl_or_default(ttl))
    end

    ##
    # Touch updates expiration time for a given key.
    #
    # Returns true if key exists, otherwise nil.
    def touch(key, ttl = nil)
      resp = perform(:touch, key, ttl_or_default(ttl))
      resp.nil? ? nil : true
    end

    ##
    # Get the value and CAS ID associated with the key.  If a block is provided,
    # value and CAS will be passed to the block.
    def get_cas(key)
      (value, cas) = perform(:cas, key)
      return [value, cas] unless block_given?

      yield value, cas
    end

    ##
    # Fetch multiple keys efficiently.
    # If a block is given, yields key/value pairs one at a time.
    # Otherwise returns a hash of { 'key' => 'value', 'key2' => 'value1' }
    def get_multi(*keys)
      keys.flatten!
      keys.compact!

      return {} if keys.empty?

      if block_given?
        pipelined_getter.process(keys) { |k, data| yield k, data.first }
      else
        {}.tap do |hash|
          pipelined_getter.process(keys) { |k, data| hash[k] = data.first }
        end
      end
    end

    ##
    # Fetch multiple keys efficiently, including available metadata such as CAS.
    # If a block is given, yields key/data pairs one a time.  Data is an array:
    # [value, cas_id]
    # If no block is given, returns a hash of
    #   { 'key' => [value, cas_id] }
    def get_multi_cas(*keys)
      if block_given?
        pipelined_getter.process(keys) { |*args| yield(*args) }
      else
        {}.tap do |hash|
          pipelined_getter.process(keys) { |k, data| hash[k] = data }
        end
      end
    end

    # Fetch the value associated with the key.
    # If a value is found, then it is returned.
    #
    # If a value is not found and no block is given, then nil is returned.
    #
    # If a value is not found (or if the found value is nil and :cache_nils is false)
    # and a block is given, the block will be invoked and its return value
    # written to the cache and returned.
    def fetch(key, ttl = nil, req_options = nil)
      req_options = req_options.nil? ? CACHE_NILS : req_options.merge(CACHE_NILS) if cache_nils
      val = get(key, req_options)
      return val unless block_given? && not_found?(val)

      new_val = yield
      add(key, new_val, ttl_or_default(ttl), req_options)
      new_val
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
    def cas(key, ttl = nil, req_options = nil, &block)
      cas_core(key, false, ttl, req_options, &block)
    end

    ##
    # like #cas, but will yield to the block whether or not the value
    # already exists.
    #
    # Returns:
    # - false if the value was changed by someone else.
    # - true if the value was successfully updated.
    def cas!(key, ttl = nil, req_options = nil, &block)
      cas_core(key, true, ttl, req_options, &block)
    end

    ##
    # Turn on quiet aka noreply support for a number of
    # memcached operations.
    #
    # All relevant operations within this block will be effectively
    # pipelined as Dalli will use 'quiet' versions.  The invoked methods
    # will all return nil, rather than their usual response.  Method
    # latency will be substantially lower, as the caller will not be
    # blocking on responses.
    #
    # Currently supports storage (set, add, replace, append, prepend),
    # arithmetic (incr, decr), flush and delete operations.  Use of
    # unsupported operations inside a block will raise an error.
    #
    # Any error replies will be discarded at the end of the block, and
    # Dalli client methods invoked inside the block will not
    # have return values
    def quiet
      old = Thread.current[::Dalli::QUIET]
      Thread.current[::Dalli::QUIET] = true
      yield
    ensure
      @ring&.pipeline_consume_and_ignore_responses
      Thread.current[::Dalli::QUIET] = old
    end
    alias multi quiet

    def set(key, value, ttl = nil, req_options = nil)
      set_cas(key, value, 0, ttl, req_options)
    end

    ##
    # Set the key-value pair, verifying existing CAS.
    # Returns the resulting CAS value if succeeded, and falsy otherwise.
    def set_cas(key, value, cas, ttl = nil, req_options = nil)
      perform(:set, key, value, ttl_or_default(ttl), cas, req_options)
    end

    ##
    # Conditionally add a key/value pair, if the key does not already exist
    # on the server.  Returns truthy if the operation succeeded.
    def add(key, value, ttl = nil, req_options = nil)
      perform(:add, key, value, ttl_or_default(ttl), req_options)
    end

    ##
    # Conditionally add a key/value pair, only if the key already exists
    # on the server.  Returns truthy if the operation succeeded.
    def replace(key, value, ttl = nil, req_options = nil)
      replace_cas(key, value, 0, ttl, req_options)
    end

    ##
    # Conditionally add a key/value pair, verifying existing CAS, only if the
    # key already exists on the server.  Returns the new CAS value if the
    # operation succeeded, or falsy otherwise.
    def replace_cas(key, value, cas, ttl = nil, req_options = nil)
      perform(:replace, key, value, ttl_or_default(ttl), cas, req_options)
    end

    # Delete a key/value pair, verifying existing CAS.
    # Returns true if succeeded, and falsy otherwise.
    def delete_cas(key, cas = 0)
      perform(:delete, key, cas)
    end

    def delete(key)
      delete_cas(key, 0)
    end

    ##
    # Append value to the value already stored on the server for 'key'.
    # Appending only works for values stored with :raw => true.
    def append(key, value)
      perform(:append, key, value.to_s)
    end

    ##
    # Prepend value to the value already stored on the server for 'key'.
    # Prepending only works for values stored with :raw => true.
    def prepend(key, value)
      perform(:prepend, key, value.to_s)
    end

    ##
    # Incr adds the given amount to the counter on the memcached server.
    # Amt must be a positive integer value.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    #
    # Note that the ttl will only apply if the counter does not already
    # exist.  To increase an existing counter and update its TTL, use
    # #cas.
    #
    # If the value already exists, it must have been set with raw: true
    def incr(key, amt = 1, ttl = nil, default = nil)
      check_positive!(amt)

      perform(:incr, key, amt.to_i, ttl_or_default(ttl), default)
    end

    ##
    # Decr subtracts the given amount from the counter on the memcached server.
    # Amt must be a positive integer value.
    #
    # memcached counters are unsigned and cannot hold negative values.  Calling
    # decr on a counter which is 0 will just return 0.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    #
    # Note that the ttl will only apply if the counter does not already
    # exist.  To decrease an existing counter and update its TTL, use
    # #cas.
    #
    # If the value already exists, it must have been set with raw: true
    def decr(key, amt = 1, ttl = nil, default = nil)
      check_positive!(amt)

      perform(:decr, key, amt.to_i, ttl_or_default(ttl), default)
    end

    ##
    # Flush the memcached server, at 'delay' seconds in the future.
    # Delay defaults to zero seconds, which means an immediate flush.
    ##
    def flush(delay = 0)
      ring.servers.map { |s| s.request(:flush, delay) }
    end
    alias flush_all flush

    ALLOWED_STAT_KEYS = %i[items slabs settings].freeze

    ##
    # Collect the stats for each server.
    # You can optionally pass a type including :items, :slabs or :settings to get specific stats
    # Returns a hash like { 'hostname:port' => { 'stat1' => 'value1', ... }, 'hostname2:port' => { ... } }
    def stats(type = nil)
      type = nil unless ALLOWED_STAT_KEYS.include? type
      values = {}
      ring.servers.each do |server|
        values[server.name.to_s] = server.alive? ? server.request(:stats, type.to_s) : nil
      end
      values
    end

    ##
    # Reset stats for each server.
    def reset_stats
      ring.servers.map do |server|
        server.alive? ? server.request(:reset_stats) : nil
      end
    end

    ##
    ## Version of the memcache servers.
    def version
      values = {}
      ring.servers.each do |server|
        values[server.name.to_s] = server.alive? ? server.request(:version) : nil
      end
      values
    end

    ##
    ## Make sure memcache servers are alive, or raise an Dalli::RingError
    def alive!
      ring.server_for_key('')
    end

    ##
    # Close our connection to each server.
    # If you perform another operation after this, the connections will be re-established.
    def close
      @ring&.close
      @ring = nil
    end
    alias reset close

    CACHE_NILS = { cache_nils: true }.freeze

    def not_found?(val)
      cache_nils ? val == ::Dalli::NOT_FOUND : val.nil?
    end

    def cache_nils
      @options[:cache_nils]
    end

    # Stub method so a bare Dalli client can pretend to be a connection pool.
    def with
      yield self
    end

    private

    def check_positive!(amt)
      raise ArgumentError, "Positive values only: #{amt}" if amt.negative?
    end

    def cas_core(key, always_set, ttl = nil, req_options = nil)
      (value, cas) = perform(:cas, key)
      return if value.nil? && !always_set

      newvalue = yield(value)
      perform(:set, key, newvalue, ttl_or_default(ttl), cas, req_options)
    end

    ##
    # Uses the argument TTL or the client-wide default.  Ensures
    # that the value is an integer
    ##
    def ttl_or_default(ttl)
      (ttl || @options[:expires_in]).to_i
    rescue NoMethodError
      raise ArgumentError, "Cannot convert ttl (#{ttl}) to an integer"
    end

    def ring
      @ring ||= Dalli::Ring.new(@normalized_servers, protocol_implementation, @options)
    end

    def protocol_implementation
      @protocol_implementation ||= case @options[:protocol]&.to_s
                                   when 'meta'
                                     Dalli::Protocol::Meta
                                   else
                                     Dalli::Protocol::Binary
                                   end
    end

    ##
    # Chokepoint method for memcached methods with a key argument.
    # Validates the key, resolves the key to the appropriate server
    # instance, and invokes the memcached method on the appropriate
    # server.
    #
    # This method also forces retries on network errors - when
    # a particular memcached instance becomes unreachable, or the
    # operational times out.
    ##
    def perform(*all_args)
      return yield if block_given?

      op, key, *args = all_args

      key = key.to_s
      key = @key_manager.validate_key(key)

      server = ring.server_for_key(key)
      server.request(op, key, *args)
    rescue NetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying request with new server' }
      retry
    end

    def normalize_options(opts)
      opts[:expires_in] = opts[:expires_in].to_i if opts[:expires_in]
      opts
    rescue NoMethodError
      raise ArgumentError, "cannot convert :expires_in => #{opts[:expires_in].inspect} to an integer"
    end

    def pipelined_getter
      PipelinedGetter.new(ring, @key_manager)
    end
  end
end
