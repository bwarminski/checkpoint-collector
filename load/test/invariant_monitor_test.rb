# ABOUTME: Verifies invariant monitor thread lifecycle and policy handling.
# ABOUTME: Covers warn, enforce, off, shutdown, and failure propagation.
require "stringio"
require_relative "test_helper"

class InvariantMonitorTest < Minitest::Test
  def test_state_increment_breaches_returns_new_count
    state = Load::InvariantMonitor::State.new

    assert_equal 1, state.increment_breaches
    assert_equal 2, state.increment_breaches
  end

  def test_sink_delegates_sample_warning_stderr_warning_and_breach_stop
    samples = []
    warnings = []
    stops = []
    stderr = StringIO.new
    sink = Load::InvariantMonitor::Sink.new(
      on_sample: ->(sample) { samples << sample.to_h },
      on_warning: ->(warning) { warnings << warning },
      on_breach_stop: ->(reason) { stops << reason },
      stderr:,
    )

    sink.sample(healthy_sample)
    sink.warning(type: "invariant_breach")
    sink.stderr_warning("warning: invariant breach")
    sink.breach_stop(:invariant_breach)

    assert_equal [healthy_sample.to_h], samples
    assert_equal [{ type: "invariant_breach" }], warnings
    assert_equal "warning: invariant breach\n", stderr.string
    assert_equal [:invariant_breach], stops
  end

  def test_enforce_policy_resets_breach_count_after_healthy_sample
    stops = []
    monitor = build_monitor(
      sampler: [
        breach_sample,
        breach_sample,
        healthy_sample,
        breach_sample,
        breach_sample,
        breach_sample,
      ],
      policy: :enforce,
      on_breach_stop: ->(reason) { stops << reason },
    )

    samples = 6.times.map { monitor.sample_once }

    assert_kind_of Load::Runner::InvariantSample, samples[2]
    assert_equal healthy_sample.to_h, samples[2].to_h
    assert_equal [:invariant_breach], stops
  end

  def test_sample_once_uses_sink_boundaries_for_sample_warning_stderr_and_breach_stop
    samples = []
    warnings = []
    stops = []
    stderr = StringIO.new

    warn_monitor = build_monitor(
      sampler: breach_sample,
      policy: :warn,
      on_sample: ->(sample) { samples << sample.to_h },
      on_warning: ->(warning) { warnings << warning },
      on_breach_stop: ->(reason) { stops << reason },
      stderr:,
    )

    enforce_monitor = build_monitor(
      sampler: [breach_sample, breach_sample, breach_sample],
      policy: :enforce,
      on_sample: ->(sample) { samples << sample.to_h },
      on_warning: ->(warning) { warnings << warning },
      on_breach_stop: ->(reason) { stops << reason },
      stderr:,
    )

    warn_monitor.sample_once
    3.times { enforce_monitor.sample_once }

    assert_equal 4, samples.length
    assert_equal 4, warnings.length
    assert_match(/warning: invariant breach:/, stderr.string)
    assert_equal [:invariant_breach], stops
  end

  def test_warn_policy_records_warning_without_triggering_stop
    warnings = []
    stops = []
    stderr = StringIO.new

    monitor = build_monitor(
      sampler: -> { breach_sample },
      policy: :warn,
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

    monitor = build_monitor(
      sampler: -> { breach_sample },
      policy: :enforce,
      on_breach_stop: ->(reason) { stops << reason },
    )

    3.times { monitor.sample_once }

    assert_equal [:invariant_breach], stops
  end

  def test_off_policy_never_starts
    monitor = build_monitor(
      sampler: -> { flunk "should not sample" },
      policy: :off,
    )

    assert_nil monitor.start
  end

  def test_stop_unblocks_sleeping_thread
    blocker = Queue.new
    sleeper_entered = Queue.new
    monitor = build_monitor(
      sampler: -> { healthy_sample },
      policy: :enforce,
      interval_seconds: 60.0,
      sleeper: ->(*) { sleeper_entered << true; blocker.pop },
    )

    thread = monitor.start
    sleeper_entered.pop

    monitor.stop(thread)

    refute thread.alive?
  end

  def test_stop_ignores_thread_error_when_target_thread_exits_during_shutdown
    thread = ExitingThread.new
    sleeper_entered = Queue.new
    monitor = build_monitor(
      sampler: -> { healthy_sample },
      policy: :enforce,
      interval_seconds: 60.0,
      sleeper: ->(*) { sleeper_entered << true; sleep },
    )
    sleeper_thread = monitor.start
    sleeper_entered.pop

    monitor.stop(thread)
    monitor.stop(sleeper_thread)

    assert_equal 1, thread.raise_calls
    assert_equal 1, thread.join_calls
  end

  def test_sampler_failure_propagates_and_clears_after_stop_raises
    stops = []
    monitor = build_monitor(
      sampler: -> { raise "boom" },
      policy: :enforce,
      on_breach_stop: ->(reason) { stops << reason },
    )

    thread = monitor.start
    thread.join

    assert_equal [:invariant_sampler_failed], stops
    assert_raises(Load::InvariantMonitor::Failure) { monitor.stop(thread) }
    monitor.stop(thread)
  end

  private

  def build_monitor(sampler:, policy:, interval_seconds: 0.0, sleeper: ->(*) {}, on_sample: ->(*) {}, on_warning: ->(*) {}, on_breach_stop: ->(*) {}, stderr: StringIO.new)
    sampler_callable =
      if sampler.respond_to?(:call)
        sampler
      else
        samples = Array(sampler)
        -> { samples.shift }
      end

    Load::InvariantMonitor.new(
      sampler: sampler_callable,
      config: Load::InvariantMonitor::Config.new(
        policy:,
        interval_seconds:,
      ),
      stop_flag: Load::Runner::InternalStopFlag.new,
      sleeper:,
      sink: Load::InvariantMonitor::Sink.new(
        on_sample:,
        on_warning:,
        on_breach_stop:,
        stderr:,
      ),
    )
  end

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
