# frozen_string_literal: true

module Dalli
  ##
  # Groups a multi-key operation's keys by server, for PipelinedGetter,
  # PipelinedSetter and PipelinedDeleter. Each of them is created for one
  # operation, and retries the whole operation after a RetryableNetworkError.
  #
  # A key with no server to go to is left out, as it always has been: a
  # server that was down before the operation started is skipped, and with
  # failover its keys go to another server. Without failover a retry is
  # different. The server was there for the first attempt and failed while
  # serving it, so if the retry finds it unreachable, the operation raises
  # Dalli::NetworkError rather than returning that server's keys as misses or
  # leaving them unwritten. With failover the keys go to another server, or
  # are left out when none is left, as for a server down from the start.
  ##
  module KeyGrouping
    NO_KEYS = [].freeze
    private_constant :NO_KEYS

    private

    # action names the operation in the debug log ('get', 'set', 'delete')
    def groups_for_keys(keys, action)
      groups = @ring.keys_grouped_by_server(keys)
      unrouted = groups.delete(nil)
      check_unrouted!(unrouted) unless @ring.failover?
      if unrouted
        Dalli.logger.debug do
          "unable to #{action} #{unrouted.length} keys because no matching server was found"
        end
      end
      groups
    end

    # The first attempt records the keys that already had no server; a retry
    # raises for any other key that has none now
    def check_unrouted!(unrouted)
      return @unrouted_on_first_attempt = unrouted || NO_KEYS unless @unrouted_on_first_attempt
      return unless unrouted

      lost = unrouted - @unrouted_on_first_attempt
      return if lost.empty?

      raise Dalli::NetworkError, "#{lost.length} keys had a server that failed during this request " \
                                 'and is still unreachable after retrying'
    end
  end
end
