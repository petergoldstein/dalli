begin
  require 'dalli'
rescue LoadError => e
  $stderr.puts "You don't have dalli installed in your application: #{e.message}"
  raise e
end
require 'digest/md5'

module ActiveSupport
  module Cache
    # A cache store implementation which stores data in Memcached:
    # http://www.danga.com/memcached/
    #
    # DalliStore implements the Strategy::LocalCache strategy which implements
    # an in memory cache inside of a block.
    class DalliStore < Store
      module Response # :nodoc:
        STORED      = "STORED\r\n"
        NOT_STORED  = "NOT_STORED\r\n"
        EXISTS      = "EXISTS\r\n"
        NOT_FOUND   = "NOT_FOUND\r\n"
        DELETED     = "DELETED\r\n"
      end

      def self.build_mem_cache(*addresses)
        addresses = addresses.flatten
        options = addresses.extract_options!
        addresses = ["localhost"] if addresses.empty?
        # No need to marshal since we marshal here.
        Dalli::Client.new(addresses, options)
      end

      # Creates a new DalliStore object, with the given memcached server
      # addresses. Each address is either a host name, or a host-with-port string
      # in the form of "host_name:port". For example:
      #
      #   ActiveSupport::Cache::DalliStore.new("localhost", "server-downstairs.localnetwork:8229")
      #
      # If no addresses are specified, then DalliStore will connect to
      # localhost port 11211 (the default memcached port).
      #
      def initialize(*addresses)
        addresses = addresses.flatten
        options = addresses.extract_options!
        if addresses.first.respond_to?(:get)
          @data = addresses.first
        else
          mem_cache_options = options.dup
          @namespace = mem_cache_options.delete(:namespace)
          @data = self.class.build_mem_cache(*(addresses + [mem_cache_options]))
        end

        extend Strategy::LocalCache
      end

      # Reads multiple keys from the cache using a single call to the
      # servers for all keys. Options can be passed in the last argument.
      def read_multi(*names)
        keys_to_names = names.inject({}){|map, name| map[escape_key(name)] = name; map}
        cache_keys = {}
        # map keys to servers
        names.each do |key|
          cache_key = escape_key key
          cache_keys[cache_key] = key
        end

        values = @data.get_multi keys_to_names.keys
        results = {}
        values.each do |key, value|
          results[cache_keys[key]] = Marshal.load value
        end
        results
      end

      # Increment a cached value. This method uses the memcached incr atomic
      # operator and can only be used on values written with the :raw option.
      # Calling it on a value not stored with :raw will initialize that value
      # to zero.
      def increment(key, amount = 1) # :nodoc:
        log("incrementing", key, amount)

        response = @data.incr(escape_key(key), amount)
        response == Response::NOT_FOUND ? nil : response
      rescue Dalli::DalliError
        nil
      end
      # Decrement a cached value. This method uses the memcached decr atomic
      # operator and can only be used on values written with the :raw option.
      # Calling it on a value not stored with :raw will initialize that value
      # to zero.
      def decrement(key, amount = 1) # :nodoc:
        log("decrement", key, amount)
        response = @data.decr(escape_key(key), amount)
        response == Response::NOT_FOUND ? nil : response
      rescue Dalli::DalliError
        nil
      end

      def reset
        @pool.reset
      end

      # Clear the entire cache on all memcached servers. This method should
      # be used with care when using a shared cache.
      def clear
        @data.flush_all
      end

      # Get the statistics from the memcached servers.
      def stats
        @data.stats
      end

      # Read an entry from the cache.
      def read(key, options = nil) # :nodoc:
        super
        value = @data.get(escape_key(key))
        return nil if value.nil?
        value = Marshal.load value
        value
      rescue Dalli::DalliError => e
        logger.error("DalliError (#{e}): #{e.message}")
        nil
      end

      # Writes a value to the cache.
      #
      # Possible options:
      # - +:unless_exist+ - set to true if you don't want to update the cache
      #   if the key is already set.
      # - +:expires_in+ - the number of seconds that this value may stay in
      #   the cache. See ActiveSupport::Cache::Store#write for an example.
      def write(key, value, options = nil)
        super
        method = options && options[:unless_exist] ? :add : :set
        value = Marshal.dump value
        @data.send(method, escape_key(key), value, expires_in(options))
      rescue Dalli::DalliError => e
        logger.error("DalliError (#{e}): #{e.message}")
        false
      end

      def delete(key, options = nil) # :nodoc:
        super
        @data.delete(escape_key(key))
      rescue Dalli::DalliError => e
        logger.error("DalliError (#{e}): #{e.message}")
        false
      end

      def exist?(key, options = nil) # :nodoc:
        # Doesn't call super, cause exist? in memcache is in fact a read
        # But who cares? Reading is very fast anyway
        # Local cache is checked first, if it doesn't know then memcache itself is read from
        !read(key, options).nil?
      end

      def delete_matched(matcher, options = nil) # :nodoc:
        # don't do any local caching at present, just pass
        # through and let the error happen
        super
        raise "Not supported by Memcache"
      end

      private

      # Exists in 2.3.8 but not in 2.3.2 so roll our own version
      def expires_in(options)
        expires_in = options && options[:expires_in]

        raise ":expires_in must be a number" if expires_in && !expires_in.is_a?(Numeric)

        expires_in || 0
      end

      def escape_key(key)
        prefix = @namespace.is_a?(Proc) ? @namespace.call : @namespace
        key = "#{prefix}:#{key}" if prefix
        key
      end
    end
  end
end