# frozen_string_literal: true

require_relative '../helper'

# Stand-in for Async::Stop: the real class inherits from Exception (not
# StandardError) so that blanket `rescue StandardError` clauses don't
# accidentally swallow scheduler-driven fiber cancellation.  We reproduce that
# hierarchy locally to avoid pulling the `async` gem just for the signal class.
# rubocop:disable Lint/InheritException
class FiberCancellation < Exception; end
# rubocop:enable Lint/InheritException

describe 'fiber concurrency' do
  # `Async::Stop < Exception` but NOT `< StandardError`, so when the scheduler
  # cancels a fiber parked on a blocking read inside a Dalli request, the
  # `rescue StandardError` branch in `Base#request` is bypassed entirely.
  # Without an `ensure` clause, `close` is never called and `abort_request!`
  # never runs — the connection is left with `@request_in_progress == true`
  # and any partial response bytes remain on the wire for a subsequent caller
  # to misread.
  #
  # `Base#request` gates its `ensure` on a local `request_local_completed`
  # flag so that pipelined_get's intentional request_in_progress=true happy
  # path is not torn down — this test proves the cleanup fires on abnormal
  # exit for non-StandardError exceptions.
  #
  # NOTE: this test uses the default `threadsafe: true` config.  The yield-
  # based interleave race (one fiber parking on IO while another enters
  # `request`) is separately protected by `Dalli::Threadsafe`, whose
  # `Monitor.synchronize` is fiber-aware under MRI and raises
  # `ThreadError: deadlock` rather than corrupting shared state.
  it 'does not leave the connection dirty when a non-StandardError aborts a request' do
    memcached_persistent do |dc|
      dc.flush
      dc.set('a', 'val_a')

      conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

      close_count = 0
      orig_close = conn_mgr.method(:close)
      conn_mgr.define_singleton_method(:close) do
        close_count += 1
        orig_close.call
      end

      # Simulate Async::Stop raised into the fiber while it's parked on the
      # response read — i.e. the scheduler cancelling mid-request.
      conn_mgr.define_singleton_method(:read_line) do
        raise FiberCancellation, 'simulated fiber cancellation'
      end

      assert_raises(FiberCancellation) { dc.get('a') }

      refute_predicate conn_mgr, :request_in_progress?,
                       'connection left with @request_in_progress == true after non-StandardError abort'
      assert_operator close_count, :>=, 1,
                      "expected close to run during non-StandardError abort, got close_count=#{close_count}"
    end
  end

  # A second Async::Stop landing on the fiber while it is already inside the
  # `ensure` cleanup from the first one would interrupt `@sock.close`.
  # `ConnectionManager#close` rescues only StandardError around the socket
  # close, so a non-StandardError escaping `@sock.close` leaves `@sock`
  # non-nil and skips `abort_request!` — the client is returned to the pool
  # with `@request_in_progress == true` and a half-closed socket.
  it 'cleans up when @sock.close itself is interrupted by a second non-StandardError' do
    memcached_persistent do |dc|
      dc.flush
      dc.set('a', 'val_a') # warms up the connection so @sock exists

      conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)
      sock = conn_mgr.instance_variable_get(:@sock)

      refute_nil sock, 'precondition: socket should be connected after set'

      # Second cancellation: fires when close() reaches @sock.close.
      sock.define_singleton_method(:close) do
        raise FiberCancellation, 'simulated second fiber cancellation during @sock.close'
      end

      # First cancellation: fires when the request parks on a read.
      conn_mgr.define_singleton_method(:read_line) do
        raise FiberCancellation, 'simulated first fiber cancellation'
      end

      assert_raises(FiberCancellation) { dc.get('a') }

      refute_predicate conn_mgr, :request_in_progress?,
                       'double-exception in ensure left @request_in_progress == true'
      refute_predicate conn_mgr, :connected?,
                       'double-exception in ensure left @sock non-nil'
    end
  end

  # `$!` (a.k.a. $ERROR_INFO) is preserved when a method is called from
  # inside a `rescue` clause.  An ensure clause that reads $! to decide
  # whether "we're unwinding from an exception" sees the *outer* rescued
  # exception even when its own begin block completed cleanly.
  #
  # On the pipelined_get happy path, @request_in_progress is intentionally
  # left true (the caller still has to drain).  An ensure that closes when
  # `$ERROR_INFO && request_in_progress?` would therefore tear the socket
  # out from under a pipelined_get whenever it's called from inside any
  # rescue clause — a common cache-fallback pattern.  This test pins the
  # local-flag implementation by exercising that exact call shape.
  #
  # NOTE: a block is required here.  Without one, single-server get_multi
  # takes the `optimized_for_single_server` path which uses :read_multi_req
  # (calls finish_request!) and would not exercise the pipelined_get
  # ensure-close window.  Passing a block forces the :pipelined_get opkey.
  it 'does not tear down a pipelined_get when called from inside a rescue clause' do
    memcached_persistent do |dc|
      dc.flush
      dc.set('a', 'val_a')
      dc.set('b', 'val_b')

      conn_mgr = dc.send(:ring).servers.first.instance_variable_get(:@connection_manager)

      close_count = 0
      orig_close = conn_mgr.method(:close)
      conn_mgr.define_singleton_method(:close) do
        close_count += 1
        orig_close.call
      end

      result = {}
      begin
        raise 'outer rescued exception'
      rescue StandardError
        # $! is set to the rescued exception while this block executes,
        # including across the get_multi call.  Block forces :pipelined_get.
        dc.get_multi(%w[a b]) { |k, v| result[k] = v }
      end

      assert_equal({ 'a' => 'val_a', 'b' => 'val_b' }, result)
      assert_equal 0, close_count,
                   "pipelined_get was torn down mid-flight (close_count=#{close_count}) " \
                   'when called from inside a rescue clause'
    end
  end
end
