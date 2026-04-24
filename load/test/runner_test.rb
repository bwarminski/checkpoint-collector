# ABOUTME: Verifies the load runner orchestrates adapter lifecycle and outcome state.
# ABOUTME: Covers readiness timeout handling, abort handling, and window pinning.
require "timeout"
require "tmpdir"
require_relative "test_helper"

class RunnerTest < Minitest::Test
  def test_runner_always_stops_adapter_and_writes_outcome
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new
    stop_flag = StopFlag.new
    SeedRecordingAction.reset!
    SeedRecordingAction.stop_flag = stop_flag
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )

    exit_code = runner.run

    assert_equal 0, exit_code
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

  def test_runner_records_adapter_metadata_before_prepare_fails
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(
      describe_response: { "name" => "rails-postgres-adapter", "framework" => "rails", "runtime" => "ruby-3.3" },
      prepare_error: Load::AdapterClient::AdapterError.new("boom"),
      adapter_bin: "adapters/rails/bin/bench-adapter",
    )
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
    assert_equal "rails-postgres-adapter", run_record.adapter.fetch(:describe).fetch("name")
    assert_equal "adapters/rails/bin/bench-adapter", run_record.adapter.fetch(:bin)
    assert_nil run_record.adapter.fetch(:app_root)
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

  def test_runner_returns_one_when_start_response_is_missing_required_fields
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(start_response: { "ok" => true })
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
      startup_grace_seconds: 0.01,
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "readiness_timeout", run_record.outcome.fetch(:error_code)
    assert_equal 1, adapter.stop_calls
    assert_equal 1, http.request_count
  end

  def test_runner_rejects_late_successful_readiness_probe
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" })
    clock = AdvancingClock.new(Time.utc(2026, 4, 21, 0, 0, 0))
    http = LateSuccessHttp.new(clock:, advance_by: 0.02)
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds) },
      http:,
      startup_grace_seconds: 0.01,
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "readiness_timeout", run_record.outcome.fetch(:error_code)
    assert_equal 1, http.request_count
    assert_nil run_record.window.dig(:readiness, :completed_at)
  end

  def test_runner_clamps_readiness_sleep_to_remaining_budget
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" })
    clock = AdvancingClock.new(Time.utc(2026, 4, 21, 0, 0, 0))
    http = ProbeHttp.new
    sleep_durations = []
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: -> { clock.now },
      sleeper: ->(seconds) { sleep_durations << seconds; clock.advance_by(seconds) },
      http:,
      startup_grace_seconds: 0.05,
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "readiness_timeout", run_record.outcome.fetch(:error_code)
    assert_equal 1, http.request_count
    assert_equal [0.05], sleep_durations
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

    grace_end = run_record.window.fetch(:readiness).fetch(:completed_at)
    first_ok = run_record.window.fetch(:start_ts)
    assert first_ok >= grace_end, "start_ts must be >= readiness completion"
  end

  def test_runner_writes_window_end_ts_before_final_outcome
    run_record = FakeRunRecord.new
    runner = build_runner_with_delayed_first_success(delay_ms: 250, run_record:)

    runner.run

    final = run_record.writes.last
    assert final.fetch(:window).key?(:end_ts)
    assert_equal false, final.fetch(:outcome).fetch(:aborted)
  end

  def test_runner_preserves_explicit_zero_seed
    SeedRecordingAction.reset!
    run_record = FakeRunRecord.new
    stop_flag = StopFlag.new
    SeedRecordingAction.stop_flag = stop_flag
    runner = Load::Runner.new(
      workload: ZeroSeedWorkload.new,
      adapter_client: FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" }),
      run_record:,
      clock: -> { Time.now.utc },
      sleeper: ->(seconds) { sleep([seconds, 0.001].min) if seconds.positive? },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      adapter_bin: "adapters/rails/bin/bench-adapter",
      stop_flag:,
    )

    exit_code = Timeout.timeout(1.0) { runner.run }

    assert_equal 0, exit_code
    assert_equal [Random.new(0).rand], SeedRecordingAction.recordings
  end

  def test_runner_uses_injected_http_client_for_worker_requests
    run_record = FakeRunRecord.new
    stop_flag = StopFlag.new
    http = CountingHttp.new(on_request: -> { stop_flag.trigger(:request_seen) })
    runner = Load::Runner.new(
      workload: HttpClientWorkload.new,
      adapter_client: FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" }),
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http:,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      adapter_bin: "adapters/rails/bin/bench-adapter",
      stop_flag:,
    )

    exit_code = runner.run

    assert_equal 0, exit_code
    assert_operator http.request_count, :>, 0
  end

  def test_runner_writes_metrics_lines_for_happy_path_run
    run_record = FakeRunRecord.new
    stop_flag = StopFlag.new
    SeedRecordingAction.reset!
    SeedRecordingAction.stop_flag = stop_flag
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )

    exit_code = runner.run

    assert_equal 0, exit_code
    assert_operator run_record.metrics_lines.length, :>, 0
  end

  def test_tracking_buffer_records_totals_and_pins_window_once
    run_record = FakeRunRecord.new
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
    )
    buffer = Load::Runner::TrackingBuffer.new(runner)

    buffer.record_ok(action: :list, latency_ns: 1, status: 200)
    first_start = run_record.window.fetch(:start_ts)
    buffer.record_ok(action: :list, latency_ns: 1, status: 200)
    buffer.record_error(action: :list, latency_ns: 1, error_class: "RuntimeError")

    runner.send(:write_state, outcome: runner.send(:outcome_payload, aborted: false))
    assert_equal first_start, run_record.window.fetch(:start_ts)
    assert_equal 3, run_record.outcome.fetch(:requests_total)
    assert_equal 2, run_record.outcome.fetch(:requests_ok)
    assert_equal 1, run_record.outcome.fetch(:requests_error)
  end

  def test_tracking_buffer_does_not_need_state_mutex_for_non_first_success
    run_record = FakeRunRecord.new
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
    )
    buffer = Load::Runner::TrackingBuffer.new(runner)
    buffer.record_ok(action: :list, latency_ns: 1, status: 200)
    completed = Queue.new
    thread = nil

    runner.instance_variable_get(:@state_mutex).synchronize do
      thread = Thread.new do
        buffer.record_ok(action: :list, latency_ns: 1, status: 200)
        completed << true
      end
      sleep 0.05
      assert_equal 1, completed.size
    end

    thread.join
  end

  def test_runner_completes_when_http_request_hangs_after_stop
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" })
    stop_flag = StopFlag.new
    runner = Load::Runner.new(
      workload: HungRequestWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: HungHttp.new(on_request: -> { stop_flag.trigger(:sigterm) }),
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )

    exit_code = Timeout.timeout(2.0) { runner.run }

    assert_equal 3, exit_code
    assert_equal 1, adapter.stop_calls
    assert_equal 0, run_record.outcome.fetch(:requests_error)
  end

  def test_drain_workers_kills_threads_that_do_not_stop
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record: FakeRunRecord.new,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
    )
    thread = Thread.new { sleep 10 }

    runner.send(:drain_workers, [thread])

    refute thread.alive?
  end

  def test_runner_returns_one_when_stop_fails_after_successful_run
    run_record = FakeRunRecord.new
    stop_flag = StopFlag.new
    SeedRecordingAction.reset!
    SeedRecordingAction.stop_flag = stop_flag
    adapter = FakeAdapterClient.new(stop_error: Load::AdapterClient::AdapterError.new("boom"))
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )

    exit_code = runner.run

    assert_equal 1, exit_code
    assert_equal "adapter_error", run_record.outcome.fetch(:error_code)
    assert_equal true, run_record.outcome.fetch(:aborted)
  end

  def test_runner_preserves_original_failure_when_stop_also_fails
    run_record = FakeRunRecord.new
    adapter = FakeAdapterClient.new(
      start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" },
      stop_error: Load::AdapterClient::AdapterError.new("boom"),
    )
    stop_flag = StopFlag.new
    runner = Load::Runner.new(
      workload: HungRequestWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: HungHttp.new(on_request: -> { stop_flag.trigger(:sigterm) }),
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )

    exit_code = Timeout.timeout(2.0) { runner.run }

    assert_equal 3, exit_code
    assert_equal "no_successful_requests", run_record.outcome.fetch(:error_code)
  end

  def test_runner_writes_spec_run_json_fields_on_happy_path
    run_record = FakeRunRecord.new
    stop_flag = StopFlag.new
    SeedRecordingAction.reset!
    SeedRecordingAction.stop_flag = stop_flag
    adapter = FakeAdapterClient.new(
      describe_response: { "name" => "rails-postgres-adapter", "framework" => "rails", "runtime" => "ruby-3.2.3" },
      start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" },
      reset_state_response: { "query_ids" => ["111", "222"] },
      adapter_bin: "adapters/rails/bin/bench-adapter",
    )
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      metrics_interval_seconds: 2.5,
      app_root: "/tmp/demo",
      workload_file: "workloads/metrics_workload.rb",
      adapter_bin: "adapters/rails/bin/bench-adapter",
      stop_flag:,
    )

    exit_code = runner.run

    assert_equal 0, exit_code
    payload = run_record.writes.last
    assert_equal File.basename(run_record.run_dir), payload.fetch(:run_id)
    assert_equal 1, payload.fetch(:schema_version)
    assert_equal "metrics-workload", payload.fetch(:workload).fetch(:name)
    assert_equal "workloads/metrics_workload.rb", payload.fetch(:workload).fetch(:file)
    assert_equal 1, payload.fetch(:workload).fetch(:actions).length
    assert_equal "/tmp/demo", payload.fetch(:adapter).fetch(:app_root)
    assert_equal "http://127.0.0.1:3999", payload.fetch(:adapter).fetch(:base_url)
    assert_equal 123, payload.fetch(:adapter).fetch(:pid)
    assert_equal "none", payload.fetch(:window).fetch(:readiness).fetch(:path)
    assert_includes payload.fetch(:window).fetch(:readiness).keys, :probe_duration_ms
    assert_includes payload.fetch(:window).fetch(:readiness).keys, :probe_attempts
    assert_equal 0.0, payload.fetch(:window).fetch(:startup_grace_seconds)
    assert_equal 2.5, payload.fetch(:window).fetch(:metrics_interval_seconds)
    assert_equal 1, payload.fetch(:outcome).fetch(:requests_total)
    assert_equal 1, payload.fetch(:outcome).fetch(:requests_ok)
    assert_equal 0, payload.fetch(:outcome).fetch(:requests_error)
    assert_equal ["111", "222"], payload.fetch(:query_ids)
    assert_equal ["metrics-workload"], adapter.reset_state_workloads
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
      startup_grace_seconds: 0.01,
    )
  end

  class FakeRunRecord
    attr_reader :outcome, :window, :adapter, :writes, :metrics_lines, :run_dir

    def initialize
      @run_dir = "runs/20260422T000000Z-fake-workload"
      @payload = {}
      @outcome = {}
      @window = {}
      @adapter = {}
      @writes = []
      @metrics_lines = []
    end

    def write_run(payload)
      @payload = payload
      @writes << payload
      @outcome = payload.fetch(:outcome, @outcome)
      @window = payload.fetch(:window, @window)
      @adapter = payload.fetch(:adapter, @adapter)
    end

    def append_metrics(payload)
      @metrics_lines << payload
    end
  end

  class FakeAdapterClient
    attr_reader :stop_calls, :describe_calls, :adapter_bin, :reset_state_workloads

    def initialize(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" }, describe_response: { "name" => "fake-adapter", "framework" => "ruby", "runtime" => "test" }, describe_error: nil, prepare_error: nil, reset_state_response: {}, adapter_bin: nil, stop_error: nil)
      @start_response = start_response
      @describe_response = describe_response
      @describe_error = describe_error
      @prepare_error = prepare_error
      @reset_state_response = reset_state_response
      @adapter_bin = adapter_bin
      @stop_error = stop_error
      @stop_calls = 0
      @describe_calls = 0
      @reset_state_workloads = []
    end

    def describe
      @describe_calls += 1
      raise @describe_error if @describe_error

      @describe_response
    end

    def prepare(app_root:)
      raise @prepare_error if @prepare_error

      true
    end

    def reset_state(app_root:, workload:, scale:)
      @reset_state_workloads << workload
      @reset_state_response
    end

    def start(app_root:)
      @start_response
    end

    def stop(pid:)
      @stop_calls += 1
      raise @stop_error if @stop_error

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

  class CountingHttp < FakeHttp
    attr_reader :request_count

    def initialize(on_request: nil)
      super(always_refuse: false)
      @request_count = 0
      @on_request = on_request
    end

    def request(*)
      @request_count += 1
      @on_request&.call
      super
    end
  end

  class HungHttp < FakeHttp
    def initialize(on_request:)
      super(always_refuse: false)
      @on_request = on_request
    end

    def request(*)
      @on_request.call
      sleep 10
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

  class LateSuccessHttp
    Response = Struct.new(:code)

    attr_reader :request_count

    def initialize(clock:, advance_by:)
      @clock = clock
      @advance_by = advance_by
      @request_count = 0
    end

    def start(*)
      @request_count += 1
      yield self
    end

    def request(*)
      @clock.advance_by(@advance_by)
      Response.new("200")
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

  SeedRecordingAction = Class.new(Load::Action) do
    Response = Struct.new(:code)

    @recordings = []

    class << self
      attr_reader :recordings
      attr_accessor :stop_flag

      def reset!
        @recordings = []
        @stop_flag = nil
      end
    end

    def name
      :seed_recording_action
    end

    def call
      self.class.recordings << rng.rand if self.class.recordings.empty?
      self.class.stop_flag.trigger(:seed_recorded) if self.class.stop_flag
      Response.new("200")
    end
  end

  class ZeroSeedWorkload < Load::Workload
    def name
      "zero-seed-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(SeedRecordingAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.1, rate_limit: :unlimited, seed: 0)
    end
  end

  class MetricsWorkload < Load::Workload
    def name
      "metrics-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(SeedRecordingAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.1, rate_limit: :unlimited, seed: 42)
    end
  end

  class HungRequestWorkload < Load::Workload
    def name
      "hung-request-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(HttpClientAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.01, rate_limit: :unlimited, seed: 42)
    end
  end

  HttpClientAction = Class.new(Load::Action) do
    def name
      :http_client_action
    end

    def call
      client.get("/todos/status?status=open")
    end
  end

  class HttpClientWorkload < Load::Workload
    def name
      "http-client-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, open_fraction: 0.0, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(HttpClientAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.01, rate_limit: :unlimited, seed: 42)
    end
  end
end
