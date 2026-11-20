# frozen_string_literal: true

module Dalli
  ##
  # The time by which the calls in a Client#with_deadline block must finish.
  # clamp takes the same arguments as ActiveSupport::Deadline#clamp.
  ##
  class Deadline
    attr_reader :expires_at

    def initialize(seconds)
      unless seconds.is_a?(Numeric) && seconds.to_f.finite?
        raise ArgumentError, "deadline must be a finite number of seconds, got #{seconds.inspect}"
      end

      @expires_at = now + seconds
    end

    def remaining
      @expires_at - now
    end

    # Returns maximum, or the time left if that's shorter. Raises error once
    # no more than minimum is left.
    def clamp(maximum, minimum: 0.0, error: Dalli::DeadlineExceededError)
      left = @expires_at - now
      raise error, 'Deadline exceeded' if left <= minimum

      [maximum, left].min
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
