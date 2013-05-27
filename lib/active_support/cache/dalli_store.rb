# encoding: ascii
require 'dalli'

module ActiveSupport
  module Cache
    class DalliStore

      attr_reader :silence, :options
      alias_method :silence?, :silence

      # Silence the logger.
      def silence!
        @silence = true
        self
      end

      # Silence the logger within a block.
      def mute
        previous_silence, @silence = defined?(@silence) && @silence, true
        yield
      ensure
        @silence = previous_silence
      end

      ESCAPE_KEY_CHARS = /[\x00-\x20%\x7F-\xFF]/

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
        @options = options.dup
        @options[:compress] ||= @options[:compression]
        @raise_errors = !!@options[:raise_errors]
        servers = if addresses.empty?
                    nil # use the default from Dalli::Client
                  else
                    addresses
                  end
        @data = Dalli::Client.new(servers, @options)

        extend Strategy::LocalCache
      end

      ##
      # Access the underlying Dalli::Client instance for
      # access to get_multi, etc.
      def dalli
        @data
      end

      def fetch(name, options=nil)
        options ||= {}
        name = expanded_key name

        if block_given?
          unless options[:force]
            entry = instrument(:read, name, options) do |payload|
              read_entry(name, options).tap do |result|
                if payload
                  payload[:super_operation] = :fetch
                  payload[:hit] = !!result
                end
              end
            end
          end

          if !entry.nil?
            instrument(:fetch_hit, name, options) { |payload| }
            entry
          else
            result = instrument(:generate, name, options) do |payload|
              yield
            end
            write(name, result, options)
            result
          end
        else
          read(name, options)
        end
      end

      def read(name, options=nil)
        options ||= {}
        name = expanded_key name

        instrument(:read, name, options) do |payload|
          entry = read_entry(name, options)
          payload[:hit] = !!entry if payload
          entry
        end
      end

      def write(name, value, options=nil)
        options ||= {}
        name = expanded_key name

        instrument(:write, name, options) do |payload|
          write_entry(name, value, options)
        end
      end

      def exist?(name, options=nil)
        options ||= {}
        name = expanded_key name

        log(:exist, name, options)
        !read_entry(name, options).nil?
      end

      def delete(name, options=nil)
        options ||= {}
        name = expanded_key name

        instrument(:delete, name, options) do |payload|
          delete_entry(name, options)
        end
      end

      # Reads multiple keys from the cache using a single call to the
      # servers for all keys. Keys must be Strings.
      def read_multi(*names)
        names.extract_options!
        mapping = names.inject({}) { |memo, name| memo[expanded_key(name)] = name; memo }
        instrument(:read_multi, names) do
          results = {}
          if local_cache
            mapping.keys.each do |key|
              if value = local_cache.read_entry(key, options)
                results[key] = value
              end
            end
          end

          results.merge!(@data.get_multi(mapping.keys - results.keys))
          results.inject({}) do |memo, (inner, _)|
            entry = results[inner]
            # NB Backwards data compatibility, to be removed at some point
            value = (entry.is_a?(ActiveSupport::Cache::Entry) ? entry.value : entry)
            memo[mapping[inner]] = value
            local_cache.write_entry(inner, value, options) if local_cache
            memo
          end
        end
      end

      # Increment a cached value. This method uses the memcached incr atomic
      # operator and can only be used on values written with the :raw option.
      # Calling it on a value not stored with :raw will fail.
      # :initial defaults to the amount passed in, as if the counter was initially zero.
      # memcached counters cannot hold negative values.
      def increment(name, amount = 1, options=nil)
        options ||= {}
        name = expanded_key name
        initial = options.has_key?(:initial) ? options[:initial] : amount
        expires_in = options[:expires_in]
        instrument(:increment, name, :amount => amount) do
          @data.incr(name, amount, expires_in, initial)
        end
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        nil
      end

      # Decrement a cached value. This method uses the memcached decr atomic
      # operator and can only be used on values written with the :raw option.
      # Calling it on a value not stored with :raw will fail.
      # :initial defaults to zero, as if the counter was initially zero.
      # memcached counters cannot hold negative values.
      def decrement(name, amount = 1, options=nil)
        options ||= {}
        name = expanded_key name
        initial = options.has_key?(:initial) ? options[:initial] : 0
        expires_in = options[:expires_in]
        instrument(:decrement, name, :amount => amount) do
          @data.decr(name, amount, expires_in, initial)
        end
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        nil
      end

      # Clear the entire cache on all memcached servers. This method should
      # be used with care when using a shared cache.
      def clear(options=nil)
        instrument(:clear, 'flushing all keys') do
          @data.flush_all
        end
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        nil
      end

      # Clear any local cache
      def cleanup(options=nil)
      end

      # Get the statistics from the memcached servers.
      def stats
        @data.stats
      end

      def reset
        @data.reset
      end

      def logger
        Dalli.logger
      end

      def logger=(new_logger)
        Dalli.logger = new_logger
      end

      protected

      # Read an entry from the cache.
      def read_entry(key, options) # :nodoc:
        entry = @data.get(key, options)
        # NB Backwards data compatibility, to be removed at some point
        entry.is_a?(ActiveSupport::Cache::Entry) ? entry.value : entry
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        nil
      end

      # Write an entry to the cache.
      def write_entry(key, value, options) # :nodoc:
        # cleanup LocalCache
        cleanup if options[:unless_exist]
        method = options[:unless_exist] ? :add : :set
        expires_in = options[:expires_in]
        @data.send(method, key, value, expires_in, options)
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        false
      end

      # Delete an entry from the cache.
      def delete_entry(key, options) # :nodoc:
        @data.delete(key)
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        false
      end

      private
      # Expand key to be a consistent string value. Invoke +cache_key+ if
      # object responds to +cache_key+. Otherwise, to_param method will be
      # called. If the key is a Hash, then keys will be sorted alphabetically.
      def expanded_key(key) # :nodoc:
        return key.cache_key.to_s if key.respond_to?(:cache_key)

        case key
        when Array
          if key.size > 1
            key = key.collect{|element| expanded_key(element)}
          else
            key = key.first
          end
        when Hash
          key = key.sort_by { |k,_| k.to_s }.collect{|k,v| "#{k}=#{v}"}
        end

        key = key.to_param
        if key.respond_to? :force_encoding
          key = key.dup
          key.force_encoding('binary')
        end
        key
      end

      def instrument(operation, key, options=nil)
        log(operation, key, options)

        payload = { :key => key }
        payload.merge!(options) if options.is_a?(Hash)
        ActiveSupport::Notifications.instrument("cache_#{operation}.active_support", payload){ yield(payload) }
      end

      def log(operation, key, options=nil)
        return unless logger && logger.debug? && !silence?
        logger.debug("Cache #{operation}: #{key}#{options.blank? ? "" : " (#{options.inspect})"}")
      end

    end
  end
end
