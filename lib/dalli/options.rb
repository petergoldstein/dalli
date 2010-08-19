require 'thread'

module Dalli

  # Auto-marshal all values in/out of memcached.
  # Otherwise, Dalli will just use to_s on all values.
  #
  # Dalli::Client.extend(Dalli::Marshal)
  #
  module Marshal
    def serialize(value)
      ::Marshal.dump(value)
    end

    def deserialize(value)
      begin
        ::Marshal.load(value)
      rescue TypeError
        raise Dalli::DalliError, "Invalid marshalled data in memcached, this happens if you switch the :marshal option and still have old data in memcached: #{value}"
      end
    end

    def append(key, value)
      raise Dalli::DalliError, "Marshalling and append do not work together"
    end

    def prepend(key, value)
      raise Dalli::DalliError, "Marshalling and prepend do not work together"
    end
  end

  # Make Dalli threadsafe by using a lock around all
  # public server methods.
  #
  # Dalli::Server.extend(Dalli::Threadsafe)
  #
  module Threadsafe
    def request(op, *args)
      lock.synchronize do
        super
      end
    end

    def alive?
      lock.synchronize do
        super
      end
    end

    def close
      lock.synchronize do
        super
      end
    end

    def lock!
      lock.mon_enter
    end

    def unlock!
      lock.mon_exit
    end

    private
    def lock
      @lock ||= Monitor.new
    end

  end
end