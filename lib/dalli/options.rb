require 'thread'

module Dalli

  # Auto-marshal all values in/out of memcached.
  # By default, Dalli will just use to_s on all values.
  #
  # Dalli::Client.extend(Dalli::Marshal)
  #
  module Marshal
    def prep(value)
      Marshal.dump(value)
    end
    
    def out(value)
      Marshal.load(value)
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

    def alive?(op, *args)
      lock.synchronize do
        super
      end
    end

    def close(op, *args)
      lock.synchronize do
        super
      end
    end

    private
    def lock
      @lock ||= Monitor.new
    end

  end
end