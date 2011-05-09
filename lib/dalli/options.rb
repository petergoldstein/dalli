require 'thread'
require 'monitor'

module Dalli

  # Make Dalli threadsafe by using a lock around all
  # public server methods.
  #
  # Dalli::Server.extend(Dalli::Threadsafe)
  #
  module Threadsafe
    attr_reader :lock
    private :lock

    def self.extended(base)
      base.instance_variable_set(:@lock, Monitor.new)
    end

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

  end
end
