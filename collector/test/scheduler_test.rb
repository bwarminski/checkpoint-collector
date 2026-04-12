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
      run_once: -> { starts << fake_clock.current_time }
    ).run_iterations(1)

    assert_equal [Time.utc(2026, 4, 12, 12, 0, 5)], slept_until
    assert_equal [Time.utc(2026, 4, 12, 12, 0, 5)], starts
  end

  def test_scheduler_skips_multiple_missed_boundaries_after_overrun
    starts = []
    slept_until = []
    fake_clock = FakeClock.new(
      Time.utc(2026, 4, 12, 12, 0, 0),
      Time.utc(2026, 4, 12, 12, 0, 17),
    )

    Scheduler.new(
      interval_seconds: 5,
      clock: -> { fake_clock.now },
      sleep_until: ->(time) do
        slept_until << time
        fake_clock.travel_to(time)
      end,
      stderr: StringIO.new,
      run_once: lambda {
        starts << fake_clock.current_time
      }
    ).run_iterations(2)

    assert_equal [
      Time.utc(2026, 4, 12, 12, 0, 0),
      Time.utc(2026, 4, 12, 12, 0, 20),
    ], starts
    assert_equal [Time.utc(2026, 4, 12, 12, 0, 20)], slept_until
  end

  def test_scheduler_waits_for_next_boundary_when_time_is_just_past_slot
    fake_clock = FakeClock.new(Time.utc(2026, 4, 12, 12, 0, 5, 500_000))
    slept_until = []

    Scheduler.new(
      interval_seconds: 5,
      clock: -> { fake_clock.now },
      sleep_until: ->(time) do
        slept_until << time
        fake_clock.travel_to(time)
      end,
      stderr: StringIO.new,
      run_once: -> {}
    ).run_iterations(1)

    assert_equal [Time.utc(2026, 4, 12, 12, 0, 10)], slept_until
  end

  def test_scheduler_logs_and_continues_after_exception
    stderr = StringIO.new
    starts = []
    fake_clock = FakeClock.new(
      Time.utc(2026, 4, 12, 12, 0, 0),
      Time.utc(2026, 4, 12, 12, 0, 5),
    )
    attempts = 0

    Scheduler.new(
      interval_seconds: 5,
      clock: -> { fake_clock.now },
      sleep_until: ->(time) { fake_clock.travel_to(time) },
      stderr: stderr,
      run_once: lambda {
        starts << fake_clock.current_time
        attempts += 1
        raise "boom" if attempts == 1
      }
    ).run_iterations(2)

    assert_includes stderr.string, "RuntimeError"
    assert_includes stderr.string, "boom"
    assert_equal 2, attempts
    assert_equal [
      Time.utc(2026, 4, 12, 12, 0, 0),
      Time.utc(2026, 4, 12, 12, 0, 5),
    ], starts
  end

  class FakeClock
    def initialize(*times)
      @times = times.dup
      @current_time = @times.fetch(0)
      @next_index = 0
    end

    def now
      @current_time = @times.fetch(@next_index)
      @next_index += 1 if @next_index < (@times.length - 1)
      @current_time
    end

    def current_time
      @current_time
    end

    def travel_to(time)
      @current_time = time
    end
  end
end
