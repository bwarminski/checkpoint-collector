# ABOUTME: Verifies invariant monitor thread lifecycle and policy handling.
# ABOUTME: Covers warn, enforce, off, shutdown, and failure propagation.
require "stringio"
require_relative "test_helper"

class InvariantMonitorTest < Minitest::Test
  def test_warn_policy_records_warning_without_triggering_stop
    warnings = []
    stops = []
    stderr = StringIO.new

    monitor = Load::InvariantMonitor.new(
      sampler: -> { breach_sample },
      policy: :warn,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(payload) { warnings << payload },
      on_breach_stop: ->(reason) { stops << reason },
      stderr:,
    )

    monitor.sample_once

    assert_equal 1, warnings.length
    assert_equal [], stops
    assert_match(/warning: invariant breach:/, stderr.string)
  end

  def test_enforce_policy_triggers_stop_after_three_consecutive_breaches
    stops = []

    monitor = Load::InvariantMonitor.new(
      sampler: -> { breach_sample },
      policy: :enforce,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(reason) { stops << reason },
      stderr: StringIO.new,
    )

    3.times { monitor.sample_once }

    assert_equal [:invariant_breach], stops
  end

  def test_off_policy_never_starts
    monitor = Load::InvariantMonitor.new(
      sampler: -> { flunk "should not sample" },
      policy: :off,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(*) {},
      stderr: StringIO.new,
    )

    assert_nil monitor.start
  end

  def test_stop_unblocks_sleeping_thread
    blocker = Queue.new
    sleeper_entered = Queue.new
    monitor = Load::InvariantMonitor.new(
      sampler: -> { healthy_sample },
      policy: :enforce,
      interval_seconds: 60.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) { sleeper_entered << true; blocker.pop },
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(*) {},
      stderr: StringIO.new,
    )

    thread = monitor.start
    sleeper_entered.pop

    monitor.stop(thread)

    refute thread.alive?
  end

  def test_stop_ignores_thread_error_when_target_thread_exits_during_shutdown
    thread = ExitingThread.new
    monitor = Load::InvariantMonitor.new(
      sampler: -> { healthy_sample },
      policy: :enforce,
      interval_seconds: 60.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(*) {},
      stderr: StringIO.new,
    )
    monitor.instance_variable_set(:@sleeping, true)

    monitor.stop(thread)

    assert_equal 1, thread.raise_calls
    assert_equal 1, thread.join_calls
  end

  def test_sampler_failure_propagates_and_clears_after_stop_raises
    stops = []
    monitor = Load::InvariantMonitor.new(
      sampler: -> { raise "boom" },
      policy: :enforce,
      interval_seconds: 0.0,
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper: ->(*) {},
      on_sample: ->(*) {},
      on_warning: ->(*) {},
      on_breach_stop: ->(reason) { stops << reason },
      stderr: StringIO.new,
    )

    thread = monitor.start
    thread.join

    assert_equal [:invariant_sampler_failed], stops
    assert_raises(Load::InvariantMonitor::Failure) { monitor.stop(thread) }
    monitor.stop(thread)
  end

  private

  def breach_sample
    Load::Runner::InvariantSample.new(
      [Load::Runner::InvariantCheck.new("open_count", 1, 5, nil)],
    )
  end

  def healthy_sample
    Load::Runner::InvariantSample.new(
      [Load::Runner::InvariantCheck.new("open_count", 10, 5, nil)],
    )
  end

  class ExitingThread
    attr_reader :raise_calls, :join_calls

    def initialize
      @raise_calls = 0
      @join_calls = 0
    end

    def alive?
      true
    end

    def raise(*)
      @raise_calls += 1
      Kernel.raise ThreadError, "thread exited during shutdown"
    end

    def join(*)
      @join_calls += 1
      true
    end
  end
end
