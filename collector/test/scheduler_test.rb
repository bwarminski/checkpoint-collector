# ABOUTME: Verifies fixed-interval scheduling behavior for the collector runtime.
# ABOUTME: Covers wall-clock alignment, overrun skip-ahead, and exception recovery.
require "minitest/autorun"
require "stringio"
require_relative "../lib/scheduler"

class SchedulerTest < Minitest::Test
  def test_scheduler_sleeps_until_next_boundary_when_started_mid_interval
    fake_clock = FakeClock.new(Time.utc(2026, 4, 12, 12, 0, 2))
    slept_until = []
    starts = []

    Scheduler.new(
      interval_seconds: 5,
      clock: -> { fake_clock.now },
      sleep_until: ->(time) do
        slept_until << time
        fake_clock.travel_to(time)
      end,
      stderr: StringIO.new,
      run_once: -> { starts << fake_clock.now }
    ).run_iterations(1)

    assert_equal [Time.utc(2026, 4, 12, 12, 0, 5)], slept_until
    assert_equal [Time.utc(2026, 4, 12, 12, 0, 5)], starts
  end

  def test_scheduler_aligns_to_next_future_boundary_after_overrun
    starts = []
    fake_clock = FakeClock.new(Time.utc(2026, 4, 12, 12, 0, 0))
    run_count = 0

    Scheduler.new(
      interval_seconds: 5,
      clock: -> { fake_clock.now },
      sleep_until: ->(time) { fake_clock.travel_to(time) },
      stderr: StringIO.new,
      run_once: lambda {
        starts << fake_clock.now
        run_count += 1
        fake_clock.travel_to(Time.utc(2026, 4, 12, 12, 0, 7)) if run_count == 1
      }
    ).run_iterations(2)

    assert_equal [
      Time.utc(2026, 4, 12, 12, 0, 0),
      Time.utc(2026, 4, 12, 12, 0, 10),
    ], starts
  end

  def test_scheduler_logs_and_continues_after_exception
    stderr = StringIO.new
    fake_clock = FakeClock.new(Time.utc(2026, 4, 12, 12, 0, 0))
    attempts = 0

    Scheduler.new(
      interval_seconds: 5,
      clock: -> { fake_clock.now },
      sleep_until: ->(time) { fake_clock.travel_to(time) },
      stderr: stderr,
      run_once: lambda {
        attempts += 1
        fake_clock.travel_to(Time.utc(2026, 4, 12, 12, 0, 5)) if attempts == 1
        raise "boom" if attempts == 1
      }
    ).run_iterations(2)

    assert_includes stderr.string, "boom"
    assert_equal 2, attempts
  end

  class FakeClock
    def initialize(current_time)
      @current_time = current_time
    end

    def now
      @current_time
    end

    def travel_to(time)
      @current_time = time
    end
  end
end
