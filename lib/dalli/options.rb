# frozen_string_literal: true

require 'monitor'

module Dalli
  # Make Dalli threadsafe by using a lock around all
  # public server methods.
  #
  # Dalli::Protocol::Binary.extend(Dalli::Threadsafe)
  #
  module Threadsafe
    def self.extended(obj)
      obj.init_threadsafe
    end

    def request(opcode, *args)
      @lock.synchronize do
        super
      end
    end

    def alive?
      @lock.synchronize do
        super
      end
    end

    def close
      @lock.synchronize do
        super
      end
    end

    def pipeline_response_setup
      @lock.synchronize do
        super
      end
    end

    def pipeline_next_responses
      @lock.synchronize do
        super
      end
    end

    def pipeline_abort
      @lock.synchronize do
        super
      end
    end

    def lock!
      @lock.mon_enter
    end

    def unlock!
      @lock.mon_exit
    end

    def init_threadsafe
      @lock = Monitor.new
    end
  end
end
