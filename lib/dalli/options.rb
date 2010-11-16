require 'thread'
require 'monitor'

module Dalli

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
