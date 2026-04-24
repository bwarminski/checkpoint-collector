# ABOUTME: Verifies the load rate limiter spaces requests correctly.
# ABOUTME: Covers unlimited and finite rate handling through injected clocks.
require_relative "test_helper"

class RateLimiterTest < Minitest::Test
  def test_unlimited_rate_never_sleeps
    limiter = Load::RateLimiter.new(rate_limit: :unlimited, clock: -> { 10.0 }, sleeper: ->(*) { flunk("unexpected sleep") })

    limiter.wait_turn
  end

  def test_finite_rate_spaces_requests
    sleeps = []
    times = [0.0, 0.0, 0.0, 0.0].each
    limiter = Load::RateLimiter.new(rate_limit: 5.0, clock: -> { times.next }, sleeper: ->(seconds) { sleeps << seconds })

    limiter.wait_turn
    limiter.wait_turn

    assert_in_delta 0.2, sleeps.first, 0.001
  end

  def test_shared_rate_limit_holds_across_multiple_workers
    worker_count = 4
    calls_per_worker = 5
    rate_limit = 10.0
    current_time = 0.0
    clock_mutex = Mutex.new
    grant_times = []
    grant_mutex = Mutex.new
    limiter = Load::RateLimiter.new(
      rate_limit: rate_limit,
      clock: -> { clock_mutex.synchronize { current_time } },
      sleeper: ->(seconds) { clock_mutex.synchronize { current_time += seconds } }
    )
    start_queue = Queue.new
    threads = worker_count.times.map do
      Thread.new do
        start_queue.pop
        calls_per_worker.times do
          limiter.wait_turn
          grant_mutex.synchronize do
            grant_times << clock_mutex.synchronize { current_time }
          end
        end
      end
    end

    worker_count.times { start_queue << true }
    threads.each(&:join)

    expected_total_calls = worker_count * calls_per_worker
    expected_duration = (expected_total_calls - 1) / rate_limit

    assert_equal expected_total_calls, grant_times.length
    assert_in_delta expected_duration, clock_mutex.synchronize { current_time }, 0.001

    grant_times.sort.each_with_index do |granted_at, index|
      assert_in_delta index / rate_limit, granted_at, 0.001
    end
  end

  def test_workers_can_sleep_concurrently_while_waiting_for_future_slots
    sleep_events = {}
    events_mutex = Mutex.new
    limiter = Load::RateLimiter.new(
      rate_limit: 10.0,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      sleeper: lambda { |seconds|
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Kernel.sleep(seconds)
        finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        events_mutex.synchronize do
          sleep_events[Thread.current[:label]] = { started_at:, finished_at: }
        end
      },
    )

    limiter.wait_turn

    slow = Thread.new do
      Thread.current[:label] = :slow
      limiter.wait_turn
    end
    Kernel.sleep(0.01)
    later = Thread.new do
      Thread.current[:label] = :later
      limiter.wait_turn
    end

    [slow, later].each(&:join)

    refute_nil sleep_events[:slow]
    refute_nil sleep_events[:later]
    assert_operator sleep_events[:later][:started_at], :<, sleep_events[:slow][:finished_at]
  end
end
