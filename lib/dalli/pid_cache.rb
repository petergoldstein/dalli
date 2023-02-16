# frozen_string_literal: true

module Dalli
  ##
  # Dalli::PIDCache is a wrapper class for PID checking to avoid system calls when checking the PID.
  ##
  module PIDCache
    if !Process.respond_to?(:fork) # JRuby or TruffleRuby
      @pid = Process.pid
      singleton_class.attr_reader(:pid)
    elsif Process.respond_to?(:_fork) # Ruby 3.1+
      class << self
        attr_reader :pid

        def update!
          @pid = Process.pid
        end
      end
      update!

      ##
      # Dalli::PIDCache::CoreExt hooks into Process to be able to reset the PID cache after fork
      ##
      module CoreExt
        def _fork
          child_pid = super
          PIDCache.update! if child_pid.zero?
          child_pid
        end
      end
      Process.singleton_class.prepend(CoreExt)
    else # Ruby 3.0 or older
      class << self
        def pid
          Process.pid
        end
      end
    end
  end
end
