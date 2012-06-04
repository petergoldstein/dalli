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
        addresses << 'localhost:11211' if addresses.empty?
        @data = Dalli::Client.new(addresses, @options)
      end

      def fetch(name, options=nil)
        options ||= {}
        name = expanded_key name

        if block_given?
          unless options[:force]
            entry = instrument(:read, name, options) do |payload|
              payload[:super_operation] = :fetch if payload
              read_entry(name, options)
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

        !read_entry(name, options).nil?
      end

      def delete(name, options=nil)
        options ||= {}
        name = expanded_key name

        delete_entry(name, options)
      end

      # Reads multiple keys from the cache using a single call to the
      # servers for all keys. Keys must be Strings.
      def read_multi(*names)
        options = names.extract_options!
        names = names.flatten
        mapping = names.inject({}) { |memo, name| memo[escape(expanded_key(name))] = name; memo }
        instrument(:read_multi, names) do
          results = @data.get_multi(mapping.keys)
          results.inject({}) do |memo, (inner, value)|
            entry = results[inner]
            # NB Backwards data compatibility, to be removed at some point
            memo[mapping[inner]] = (entry.is_a?(ActiveSupport::Cache::Entry) ? entry.value : entry)
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
        @data.flush_all
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        nil
      end

      # Get the statistics from the memcached servers.
      def stats
        @data.stats
      end

      def reset
        @data.reset
      end

      protected

      # Read an entry from the cache.
      def read_entry(key, options) # :nodoc:
        entry = @data.get(escape(key), options)
        # NB Backwards data compatibility, to be removed at some point
        entry.is_a?(ActiveSupport::Cache::Entry) ? entry.value : entry
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        nil
      end

      # Write an entry to the cache.
      def write_entry(key, value, options) # :nodoc:
        method = options[:unless_exist] ? :add : :set
        expires_in = options[:expires_in]
        @data.send(method, escape(key), value, expires_in, options)
      rescue Dalli::DalliError => e
        logger.error("DalliError: #{e.message}") if logger
        raise if @raise_errors
        false
      end

      # Delete an entry from the cache.
      def delete_entry(key, options) # :nodoc:
        @data.delete(escape(key))
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

        key.to_param
      end

      def escape(key)
        key = key.to_s.dup
        key = key.force_encoding("BINARY") if key.encoding_aware?
        key = key.gsub(ESCAPE_KEY_CHARS){ |match| "%#{match.getbyte(0).to_s(16).upcase}" }
        key
      end

      def instrument(operation, key, options=nil)
        log(operation, key, options)

        if ActiveSupport::Cache::Store.instrument
          payload = { :key => key }
          payload.merge!(options) if options.is_a?(Hash)
          ActiveSupport::Notifications.instrument("cache_#{operation}.active_support", payload){ yield(payload) }
        else
          yield(nil)
        end
      end

      def log(operation, key, options=nil)
        return unless logger && logger.debug? && !silence?
        logger.debug("Cache #{operation}: #{key}#{options.blank? ? "" : " (#{options.inspect})"}")
      end

      def logger
        Dalli.logger
      end

    end
  end
end
