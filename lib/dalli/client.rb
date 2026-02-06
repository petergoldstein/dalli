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
    # - :raw        - If set, disables serialization and compression entirely at the client level.
    #                 Only String values are supported. This is useful when the caller handles its own
    #                 serialization (e.g., Rails' ActiveSupport::Cache). Note: this is different from
    #                 the per-request :raw option which converts values to strings but still uses the
    #                 serialization pipeline.
    # - :digest_class - defaults to Digest::MD5, allows you to pass in an object that responds to the hexdigest method,
    #                   useful for injecting a FIPS compliant hash object.
    # - :protocol - one of either :binary or :meta, defaulting to :binary.  This sets the protocol that Dalli uses
    #               to communicate with memcached.
    # - :otel_db_statement - controls the +db.query.text+ span attribute when OpenTelemetry is loaded.
    #                        +:include+ logs the full operation and key(s), +:obfuscate+ replaces keys with "?",
    #                        +nil+ (default) omits the attribute entirely.
    # - :otel_peer_service - when set, adds a +peer.service+ span attribute with this value for logical service naming.
    #
    def initialize(servers = nil, options = {})
      @normalized_servers = ::Dalli::ServersArgNormalizer.normalize_servers(servers)
      @options = normalize_options(options)
      @key_manager = ::Dalli::KeyManager.new(@options)
      @ring = nil
      emit_deprecation_warnings
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
    # Get value with extended metadata using the meta protocol.
    #
    # IMPORTANT: This method requires memcached 1.6+ and the meta protocol (protocol: :meta).
    # It will raise an error if used with the binary protocol.
    #
    # @param key [String] the cache key
    # @param options [Hash] options controlling what metadata to return
    #   - :return_cas [Boolean] return the CAS value (default: true)
    #   - :return_hit_status [Boolean] return whether item was previously accessed
    #   - :return_last_access [Boolean] return seconds since last access
    #   - :skip_lru_bump [Boolean] don't bump LRU or update access stats
    #
    # @return [Hash] containing:
    #   - :value - the cached value (or nil on miss)
    #   - :cas - the CAS value
    #   - :hit_before - true/false if previously accessed (only if return_hit_status: true)
    #   - :last_access - seconds since last access (only if return_last_access: true)
    #
    # @example Get with hit status
    #   result = client.get_with_metadata('key', return_hit_status: true)
    #   # => { value: "data", cas: 123, hit_before: true }
    #
    # @example Get with all metadata without affecting LRU
    #   result = client.get_with_metadata('key',
    #     return_hit_status: true,
    #     return_last_access: true,
    #     skip_lru_bump: true
    #   )
    #   # => { value: "data", cas: 123, hit_before: true, last_access: 42 }
    #
    def get_with_metadata(key, options = {})
      raise_unless_meta_protocol!

      key = key.to_s
      key = @key_manager.validate_key(key)

      server = ring.server_for_key(key)
      Instrumentation.trace('get_with_metadata', trace_attrs('get_with_metadata', key, server)) do
        server.request(:meta_get, key, options)
      end
    rescue NetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying get_with_metadata with new server' }
      retry
    end

    ##
    # Fetch multiple keys efficiently.
    # If a block is given, yields key/value pairs one at a time.
    # Otherwise returns a hash of { 'key' => 'value', 'key2' => 'value1' }
    # rubocop:disable Style/ExplicitBlockArgument
    def get_multi(*keys)
      keys.flatten!
      keys.compact!
      return {} if keys.empty?

      if block_given?
        get_multi_yielding(keys) { |k, v| yield k, v }
      else
        get_multi_hash(keys)
      end
    end
    # rubocop:enable Style/ExplicitBlockArgument

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
    # Fetch the value with thundering herd protection using the meta protocol's
    # N (vivify) and R (recache) flags.
    #
    # This method prevents multiple clients from simultaneously regenerating the same
    # cache entry (the "thundering herd" problem). Only one client wins the right to
    # regenerate; other clients receive the stale value (if available) or wait.
    #
    # IMPORTANT: This method requires memcached 1.6+ and the meta protocol (protocol: :meta).
    # It will raise an error if used with the binary protocol.
    #
    # @param key [String] the cache key
    # @param ttl [Integer] time-to-live for the cached value in seconds
    # @param lock_ttl [Integer] how long the lock/stub lives (default: 30 seconds)
    #   This is the maximum time other clients will return stale data while
    #   waiting for regeneration. Should be longer than your expected regeneration time.
    # @param recache_threshold [Integer, nil] if set, win the recache race when the
    #   item's remaining TTL is below this threshold. Useful for proactive recaching.
    # @param req_options [Hash] options passed to set operations (e.g., raw: true)
    #
    # @yield Block to regenerate the value (only called if this client won the race)
    # @return [Object] the cached value (may be stale if another client is regenerating)
    #
    # @example Basic usage
    #   client.fetch_with_lock('expensive_key', ttl: 300, lock_ttl: 30) do
    #     expensive_database_query
    #   end
    #
    # @example With proactive recaching (recache before expiry)
    #   client.fetch_with_lock('key', ttl: 300, lock_ttl: 30, recache_threshold: 60) do
    #     expensive_operation
    #   end
    #
    def fetch_with_lock(key, ttl: nil, lock_ttl: 30, recache_threshold: nil, req_options: nil, &block)
      raise ArgumentError, 'Block is required for fetch_with_lock' unless block_given?

      raise_unless_meta_protocol!

      key = key.to_s
      key = @key_manager.validate_key(key)

      server = ring.server_for_key(key)
      Instrumentation.trace('fetch_with_lock', trace_attrs('fetch_with_lock', key, server)) do
        fetch_with_lock_request(key, ttl, lock_ttl, recache_threshold, req_options, &block)
      end
    rescue NetworkError => e
      Dalli.logger.debug { e.inspect }
      Dalli.logger.debug { 'retrying fetch_with_lock with new server' }
      retry
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
    def cas(key, ttl = nil, req_options = nil, &)
      cas_core(key, false, ttl, req_options, &)
    end

    ##
    # like #cas, but will yield to the block whether or not the value
    # already exists.
    #
    # Returns:
    # - false if the value was changed by someone else.
    # - true if the value was successfully updated.
    def cas!(key, ttl = nil, req_options = nil, &)
      cas_core(key, true, ttl, req_options, &)
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
    # Set multiple keys and values efficiently using pipelining.
    # This method is more efficient than calling set() in a loop because
    # it batches requests by server and uses quiet mode.
    #
    # @param hash [Hash] key-value pairs to set
    # @param ttl [Integer] time-to-live in seconds (optional, uses default if not provided)
    # @param req_options [Hash] options passed to each set operation
    # @return [void]
    #
    # Example:
    #   client.set_multi({ 'key1' => 'value1', 'key2' => 'value2' }, 300)
    def set_multi(hash, ttl = nil, req_options = nil)
      return if hash.empty?

      Instrumentation.trace('set_multi', multi_trace_attrs('set_multi', hash.size, hash.keys)) do
        pipelined_setter.process(hash, ttl_or_default(ttl), req_options)
      end
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
    # Delete multiple keys efficiently using pipelining.
    # This method is more efficient than calling delete() in a loop because
    # it batches requests by server and uses quiet mode.
    #
    # @param keys [Array<String>] keys to delete
    # @return [void]
    #
    # Example:
    #   client.delete_multi(['key1', 'key2', 'key3'])
    def delete_multi(keys)
      return if keys.empty?

      Instrumentation.trace('delete_multi', multi_trace_attrs('delete_multi', keys.size, keys)) do
        pipelined_deleter.process(keys)
      end
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

    # Records hit/miss metrics on a span for cache observability.
    # @param span [OpenTelemetry::Trace::Span, nil] the span to record on
    # @param key_count [Integer] total keys requested
    # @param hit_count [Integer] keys found in cache
    def record_hit_miss_metrics(span, key_count, hit_count)
      return unless span

      span.add_attributes('db.memcached.hit_count' => hit_count,
                          'db.memcached.miss_count' => key_count - hit_count)
    end

    def get_multi_yielding(keys)
      Instrumentation.trace_with_result('get_multi', get_multi_attributes(keys)) do |span|
        hit_count = 0
        pipelined_getter.process(keys) do |k, data|
          hit_count += 1
          yield k, data.first
        end
        record_hit_miss_metrics(span, keys.size, hit_count)
        nil
      end
    end

    def get_multi_hash(keys)
      Instrumentation.trace_with_result('get_multi', get_multi_attributes(keys)) do |span|
        {}.tap do |hash|
          pipelined_getter.process(keys) { |k, data| hash[k] = data.first }
          record_hit_miss_metrics(span, keys.size, hash.size)
        end
      end
    end

    def get_multi_attributes(keys)
      multi_trace_attrs('get_multi', keys.size, keys)
    end

    def trace_attrs(operation, key, server)
      attrs = { 'db.operation.name' => operation, 'server.address' => server.hostname }
      attrs['server.port'] = server.port if server.socket_type == :tcp
      attrs['peer.service'] = @options[:otel_peer_service] if @options[:otel_peer_service]
      add_query_text(attrs, operation, key)
    end

    def multi_trace_attrs(operation, key_count, keys)
      attrs = { 'db.operation.name' => operation, 'db.memcached.key_count' => key_count }
      attrs['peer.service'] = @options[:otel_peer_service] if @options[:otel_peer_service]
      add_query_text(attrs, operation, keys)
    end

    def add_query_text(attrs, operation, key_or_keys)
      case @options[:otel_db_statement]
      when :include
        attrs['db.query.text'] = "#{operation} #{Array(key_or_keys).join(' ')}"
      when :obfuscate
        attrs['db.query.text'] = "#{operation} ?"
      end
      attrs
    end

    def check_positive!(amt)
      raise ArgumentError, "Positive values only: #{amt}" if amt.negative?
    end

    def cas_core(key, always_set, ttl = nil, req_options = nil)
      (value, cas) = perform(:cas, key)
      return if value.nil? && !always_set

      newvalue = yield(value)
      perform(:set, key, newvalue, ttl_or_default(ttl), cas, req_options)
    end

    def fetch_with_lock_request(key, ttl, lock_ttl, recache_threshold, req_options)
      server = ring.server_for_key(key)
      result = server.request(:meta_get, key, { vivify_ttl: lock_ttl, recache_ttl: recache_threshold })

      return result[:value] unless result[:won_recache]

      new_val = yield
      set(key, new_val, ttl_or_default(ttl), req_options)
      new_val
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
      Instrumentation.trace(op.to_s, trace_attrs(op.to_s, key, server)) do
        server.request(op, key, *args)
      end
    rescue RetryableNetworkError => e
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

    def pipelined_setter
      PipelinedSetter.new(ring, @key_manager)
    end

    def pipelined_deleter
      PipelinedDeleter.new(ring, @key_manager)
    end

    def raise_unless_meta_protocol!
      return if protocol_implementation == Dalli::Protocol::Meta

      raise Dalli::DalliError,
            'This operation requires the meta protocol (memcached 1.6+). ' \
            'Use protocol: :meta when creating the client.'
    end

    include ProtocolDeprecations
  end
end
