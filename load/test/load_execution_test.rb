# ABOUTME: Verifies worker construction, reporter lifecycle, and load-window behavior.
# ABOUTME: Covers timeout triggering, first-success signaling, and request-total aggregation.
require "stringio"
require_relative "test_helper"

class LoadExecutionTest < Minitest::Test
  StartupFailure = Class.new(StandardError)

  def test_returns_request_totals_with_at_least_one_success
    ready = Queue.new
    release = Queue.new
    stop_flag = Load::Runner::InternalStopFlag.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: barrier_action_class(ready:, release:), workers: 1, duration_seconds: 60.0),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(stop_flag:, sleeper: ->(*) {}),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )

    thread = Thread.new { execution.run(mode: :finite, duration_seconds: 60.0) }
    ready.pop
    stop_flag.trigger(:timeout)
    release << true
    result = thread.value

    assert_operator result.fetch(:ok), :>=, 1
  end

  def test_finite_mode_triggers_timeout_stop_reason
    stop_flag = Load::Runner::InternalStopFlag.new
    clock = AdvancingClock.new(Time.utc(2026, 4, 26, 0, 0, 0))
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: fast_action_class, workers: 1, duration_seconds: 0.5),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(stop_flag:, clock:, sleeper: ->(seconds) { clock.advance_by(seconds) }),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )

    execution.run(mode: :finite, duration_seconds: 0.5)

    assert_equal :timeout, stop_flag.reason
  end

  def test_continuous_mode_waits_for_stop_flag
    stop_flag = Load::Runner::InternalStopFlag.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: fast_action_class, workers: 1, duration_seconds: 60.0),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(stop_flag:, sleeper: ->(*) { stop_flag.trigger(:sigterm) }),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )

    result = execution.run(mode: :continuous, duration_seconds: 60.0)

    assert_equal :sigterm, stop_flag.reason
    assert_operator result.fetch(:total), :>=, 0
  end

  def test_on_first_success_fires_once_across_concurrent_workers
    calls = Queue.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: fast_action_class, workers: 16, duration_seconds: 0.01),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(sleeper: ->(*) {}),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> { calls << true },
      reporter_factory: ->(**) { FakeReporter.new },
    )

    execution.run(mode: :finite, duration_seconds: 0.01)

    assert_equal 1, calls.size
  end

  def test_reporter_stops_when_wait_raises
    reporter = FakeReporter.new
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: fast_action_class, workers: 1, duration_seconds: 60.0),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(sleeper: lambda { |_| raise "boom" }),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { reporter },
    )

    error = assert_raises(RuntimeError) { execution.run(mode: :finite, duration_seconds: 60.0) }

    assert_equal "boom", error.message
    assert_equal 1, reporter.stop_calls
  end

  def test_tracking_buffer_is_named_class
    buffer = Load::LoadExecution::TrackingBuffer.new(on_first_success: -> {})

    assert_equal "Load::LoadExecution::TrackingBuffer", buffer.class.name
  end

  def test_tracking_buffer_records_totals_and_calls_on_first_success_once
    calls = 0
    buffer = Load::LoadExecution::TrackingBuffer.new(on_first_success: -> { calls += 1 })

    buffer.record_ok(action: :list, latency_ns: 1, status: 200)
    buffer.record_ok(action: :list, latency_ns: 1, status: 200)
    buffer.record_error(action: :list, latency_ns: 1, error_class: "RuntimeError")

    assert_equal 1, calls
    assert_equal({ total: 3, ok: 2, error: 1 }, buffer.request_totals)
  end

  def test_drain_threads_kills_threads_that_do_not_stop
    execution = Load::LoadExecution.new(
      workload: build_workload(action_class: fast_action_class, workers: 1, duration_seconds: 1.0),
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(sleeper: ->(*) {}),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )
    thread = Thread.new { sleep 10 }

    execution.send(:drain_threads, [thread])

    refute thread.alive?
  end

  def test_run_preserves_pre_startup_exception
    workload = Object.new
    workload.define_singleton_method(:actions) { raise StartupFailure, "boom" }
    workload.define_singleton_method(:load_plan) { Load::LoadPlan.new(workers: 1, duration_seconds: 1.0, rate_limit: :unlimited, seed: 42) }
    workload.define_singleton_method(:scale) { Load::Scale.new(rows_per_table: 1, seed: 42) }

    execution = Load::LoadExecution.new(
      workload:,
      base_url: "http://127.0.0.1:3000",
      runtime: runtime(sleeper: ->(*) {}),
      metrics_interval_seconds: 5.0,
      run_record: FakeRunRecord.new,
      on_first_success: -> {},
      reporter_factory: ->(**) { FakeReporter.new },
    )

    error = assert_raises(StartupFailure) { execution.run(mode: :finite, duration_seconds: 1.0) }

    assert_equal "boom", error.message
  end

  private

  def build_workload(action_class:, workers:, duration_seconds:)
    Class.new(Load::Workload) do
      define_method(:name) { "fixture-workload" }
      define_method(:scale) { Load::Scale.new(rows_per_table: 1, seed: 42) }
      define_method(:actions) { [Load::ActionEntry.new(action_class, 1)] }
      define_method(:load_plan) { Load::LoadPlan.new(workers:, duration_seconds:, rate_limit: :unlimited, seed: 42) }
    end.new
  end

  def fast_action_class
    response_class = Struct.new(:code)
    Class.new(Load::Action) do
      def name
        :fast
      end

      define_method(:call) { response_class.new("200") }
    end
  end

  def barrier_action_class(ready:, release:)
    response_class = Struct.new(:code)
    Class.new(Load::Action) do
      define_method(:name) { :barrier }

      define_method(:call) do
        ready << true
        release.pop
        response_class.new("200")
      end
    end
  end

  def runtime(stop_flag: Load::Runner::InternalStopFlag.new, clock: -> { Time.now.utc }, sleeper:)
    Load::Runner::Runtime.new(clock, sleeper, FakeHttp.new, stop_flag)
  end

  class FakeRunRecord
    attr_reader :metrics_lines

    def initialize
      @metrics_lines = []
    end

    def append_metrics(payload)
      @metrics_lines << payload
    end
  end

  class FakeReporter
    attr_reader :start_calls, :stop_calls

    def initialize
      @start_calls = 0
      @stop_calls = 0
    end

    def start
      @start_calls += 1
    end

    def stop
      @stop_calls += 1
    end
  end

  class FakeHttp
    Response = Struct.new(:code)

    def start(*)
      yield self
    end

    def request(*)
      Response.new("200")
    end
  end

  class AdvancingClock
    def initialize(current_time)
      @current_time = current_time
    end

    def call
      @current_time
    end

    def advance_by(seconds)
      @current_time += seconds
    end
  end
end
