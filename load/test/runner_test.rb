# ABOUTME: Verifies the load runner orchestrates adapter lifecycle and outcome state.
# ABOUTME: Covers readiness timeout handling, abort handling, and window start pinning.
require "tmpdir"
require_relative "test_helper"

class RunnerTest < Minitest::Test
  def test_runner_always_stops_adapter_and_writes_outcome
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new
    runner = Load::Runner.new(workload: FakeWorkload.new, adapter_client: adapter, run_record:, clock: fake_clock, sleeper: ->(*) {}, http: FakeHttp.new)

    runner.run

    assert_equal 1, adapter.stop_calls
    assert_equal false, run_record.outcome.fetch(:aborted)
  end

  def test_runner_sets_aborted_true_on_sigint_and_still_stops_adapter
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new
    stop_flag = StopFlag.new
    sleeper = ->(*) { stop_flag.trigger(:sigint) }
    runner = Load::Runner.new(workload: FakeWorkload.new, adapter_client: adapter, run_record:, clock: fake_clock, sleeper:, http: FakeHttp.new, stop_flag:)

    runner.run

    assert_equal true, run_record.outcome.fetch(:aborted)
    assert_equal 1, adapter.stop_calls
  end

  def test_runner_returns_one_when_adapter_describe_fails
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(describe_error: Load::AdapterClient::AdapterError.new("boom"))
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
      adapter_bin: "adapters/rails/bin/bench-adapter",
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "adapter_error", run_record.outcome.fetch(:error_code)
    assert_equal 0, adapter.stop_calls
  end

  def test_runner_readiness_probe_exits_one_on_timeout
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" })
    clock = AdvancingClock.new(Time.utc(2026, 4, 21, 0, 0, 0))
    http = ProbeHttp.new
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds) },
      http:,
      readiness_timeout_seconds: 999,
      startup_grace_seconds: 0.01,
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "readiness_timeout", run_record.outcome.fetch(:error_code)
    assert_equal 1, adapter.stop_calls
    assert_equal 1, http.request_count
  end

  def test_runner_readiness_probe_does_not_retry_after_deadline
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" })
    clock = AdvancingClock.new(Time.utc(2026, 4, 21, 0, 0, 0))
    http = ProbeHttp.new
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds) },
      http:,
      readiness_timeout_seconds: 999,
      startup_grace_seconds: 0.01,
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "readiness_timeout", run_record.outcome.fetch(:error_code)
    assert_equal 1, http.request_count
  end

  def test_runner_records_adapter_describe_metadata_before_readiness
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(describe_response: { "name" => "rails-postgres-adapter", "framework" => "rails", "runtime" => "ruby-3.3" })
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
      adapter_bin: "adapters/rails/bin/bench-adapter",
    )

    runner.run

    assert_equal 1, adapter.describe_calls
    assert_equal "rails-postgres-adapter", run_record.adapter.fetch(:describe).fetch("name")
    assert_equal "rails", run_record.adapter.fetch(:describe).fetch("framework")
    assert_equal "ruby-3.3", run_record.adapter.fetch(:describe).fetch("runtime")
    assert_equal "adapters/rails/bin/bench-adapter", run_record.adapter.fetch(:bin)
  end

  def test_runner_pins_window_start_ts_at_first_successful_request
    run_record = FakeRunRecord.new
    runner = build_runner_with_delayed_first_success(delay_ms: 250, run_record:)

    runner.run

    grace_end = run_record.readiness.fetch(:completed_at)
    first_ok = run_record.window.fetch(:start_ts)
    assert first_ok >= grace_end, "start_ts must be >= readiness completion"
  end

  private

  def fake_clock
    -> { Time.now.utc }
  end

  def build_runner_with_delayed_first_success(delay_ms:, run_record:)
    adapter = FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" })
    Load::Runner.new(
      workload: DelayedWorkload.new(delay_ms:),
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
      readiness_timeout_seconds: 0.1,
      startup_grace_seconds: 0.01,
    )
  end

  class FakeRunRecord
    attr_reader :outcome, :readiness, :window, :adapter

    def initialize
      @payload = {}
      @outcome = {}
      @readiness = {}
      @window = {}
      @adapter = {}
    end

    def write_run(payload)
      @payload = payload
      @outcome = payload.fetch(:outcome, @outcome)
      @readiness = payload.fetch(:readiness, @readiness)
      @window = payload.fetch(:window, @window)
      @adapter = payload.fetch(:adapter, @adapter)
    end
  end

  class FakeAdapterClient
    attr_reader :stop_calls, :describe_calls, :adapter_bin

    def initialize(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" }, describe_response: { "name" => "fake-adapter", "framework" => "ruby", "runtime" => "test" }, describe_error: nil, adapter_bin: nil)
      @start_response = start_response
      @describe_response = describe_response
      @describe_error = describe_error
      @adapter_bin = adapter_bin
      @stop_calls = 0
      @describe_calls = 0
    end

    def describe
      @describe_calls += 1
      raise @describe_error if @describe_error

      @describe_response
    end

    def prepare(app_root:)
      true
    end

    def reset_state(app_root:, scale:)
      true
    end

    def start(app_root:)
      @start_response
    end

    def stop(pid:)
      @stop_calls += 1
      true
    end
  end

  class FakeHttp
    Response = Struct.new(:code)

    def initialize(always_refuse: false)
      @always_refuse = always_refuse
    end

    def start(*)
      raise Errno::ECONNREFUSED, "connection refused" if @always_refuse

      yield self
    end

    def request(*)
      Response.new("200")
    end
  end

  class ProbeHttp
    Response = Struct.new(:code)

    attr_reader :request_count

    def initialize
      @request_count = 0
    end

    def start(*)
      @request_count += 1
      if @request_count > 2
        raise RuntimeError, "unexpected third probe request"
      end

      yield self
    end

    def request(*)
      Response.new("503")
    end
  end

  class StopFlag
    attr_reader :reason

    def initialize
      @reason = nil
      @mutex = Mutex.new
    end

    def trigger(reason)
      @mutex.synchronize do
        @reason = reason
      end
    end

    def call
      @mutex.synchronize do
        !@reason.nil?
      end
    end
  end

  class AdvancingClock
    def initialize(current_time)
      @current_time = current_time
    end

    def now
      @current_time
    end

    def advance_by(seconds)
      @current_time += seconds
    end
  end

  class FakeWorkload < Load::Workload
    def name
      "fake-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(FastAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.05, rate_limit: :unlimited, seed: 42)
    end
  end

  class DelayedWorkload < Load::Workload
    def initialize(delay_ms:)
      @delay_ms = delay_ms
    end

    def name
      "delayed-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(DelayedSuccessAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.3, rate_limit: :unlimited, seed: 42)
    end

    def delay_ms
      @delay_ms
    end
  end

  FastAction = Class.new(Load::Action) do
    FastResponse = Struct.new(:code)

    def name
      :fast_action
    end

    def call
      FastResponse.new("200")
    end
  end

  DelayedSuccessAction = Class.new(Load::Action) do
    DelayedResponse = Struct.new(:code)

    def name
      :delayed_success_action
    end

    def call
      sleep(0.25)
      DelayedResponse.new("200")
    end
  end
end
