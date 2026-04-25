# ABOUTME: Verifies the load runner orchestrates adapter lifecycle and outcome state.
# ABOUTME: Covers readiness timeout handling, abort handling, and window pinning.
require "timeout"
require "tmpdir"
require "stringio"
require_relative "test_helper"
require_relative "../../workloads/missing_index_todos/actions/close_todo"
require_relative "../../workloads/missing_index_todos/actions/create_todo"
require_relative "../../workloads/missing_index_todos/actions/delete_completed_todos"

class RunnerTest < Minitest::Test
  def test_runner_calls_verifier_after_start_and_readiness_and_before_workers
    call_order = []
    stop_flag = StopFlag.new
    VerifierOrderAction.reset!
    VerifierOrderAction.call_order = call_order
    VerifierOrderAction.stop_flag = stop_flag
    adapter = FakeAdapterClient.new(call_order:)
    verifier_calls = []
    verifier = lambda do |base_url:|
      call_order << :verify
      verifier_calls << base_url
      { ok: true }
    end
    runner = Load::Runner.new(
      workload: VerifierOrderWorkload.new,
      adapter_client: adapter,
      run_record: FakeRunRecord.new,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: ReadinessLoggingHttp.new(call_order:),
      startup_grace_seconds: 0.1,
      stop_flag:,
      verifier:,
      mode: :finite,
    )

    exit_code = runner.run

    assert_equal 0, exit_code
    assert_equal ["http://127.0.0.1:3999"], verifier_calls
    assert_equal [:describe, :prepare, :reset_state, :start, :readiness, :verify, :worker, :stop], call_order
  end

  def test_runner_calls_verifier_for_continuous_runs_when_present
    call_order = []
    stop_flag = StopFlag.new
    VerifierOrderAction.reset!
    VerifierOrderAction.call_order = call_order
    VerifierOrderAction.stop_flag = stop_flag
    adapter = FakeAdapterClient.new(call_order:)
    verifier_calls = []
    verifier = lambda do |base_url:|
      call_order << :verify
      verifier_calls << base_url
      { ok: true }
    end
    runner = Load::Runner.new(
      workload: VerifierOrderWorkload.new,
      adapter_client: adapter,
      run_record: FakeRunRecord.new,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: ReadinessLoggingHttp.new(call_order:),
      startup_grace_seconds: 0.1,
      stop_flag:,
      verifier:,
      mode: :continuous,
      invariant_sampler: FakeInvariantSampler.new([]),
    )

    exit_code = runner.run

    assert_equal 0, exit_code
    assert_equal ["http://127.0.0.1:3999"], verifier_calls
    assert_equal [:describe, :prepare, :reset_state, :start, :readiness, :verify, :worker, :stop], call_order
  end

  def test_runner_aborts_before_workers_when_verifier_fails
    stop_flag = StopFlag.new
    call_order = []
    VerifierOrderAction.reset!
    VerifierOrderAction.call_order = call_order
    VerifierOrderAction.stop_flag = stop_flag
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: File.join(dir, "run"))
      adapter = FakeAdapterClient.new(call_order:)
      verifier = lambda do |base_url:|
        call_order << :verify
        raise Load::FixtureVerifier::VerificationError, "counts pathology missing for #{base_url}"
      end
      runner = Load::Runner.new(
        workload: VerifierOrderWorkload.new,
        adapter_client: adapter,
        run_record:,
        clock: fake_clock,
        sleeper: ->(*) { Thread.pass },
        http: ReadinessLoggingHttp.new(call_order:),
        startup_grace_seconds: 0.1,
        stop_flag:,
        verifier:,
        mode: :finite,
      )

      exit_code = runner.run

      assert_equal Load::ExitCodes::ADAPTER_ERROR, exit_code
      assert_equal [:describe, :prepare, :reset_state, :start, :readiness, :verify, :stop], call_order
      assert_equal 1, adapter.stop_calls
      refute File.exist?(run_record.metrics_path)

      payload = JSON.parse(File.read(run_record.run_path))
      assert_equal "fixture_verification_failed", payload.dig("outcome", "error_code")
    end
  end

  def test_runner_requires_workload_provided_invariant_sampler_for_continuous_mode
    error = assert_raises(Load::AdapterClient::AdapterError) do
      Load::Runner.new(
        workload: MetricsWorkload.new,
        adapter_client: FakeAdapterClient.new,
        run_record: FakeRunRecord.new,
        clock: fake_clock,
        sleeper: ->(*) { Thread.pass },
        http: FakeHttp.new,
        readiness_path: nil,
        startup_grace_seconds: 0.0,
        mode: :continuous,
        database_url: nil,
      )
    end

    assert_equal "continuous mode requires the workload to provide an invariant sampler", error.message
  end

  def test_runner_asks_workload_for_invariant_sampler_in_continuous_mode
    workload = RecordingSamplerWorkload.new

    Load::Runner.new(
      workload:,
      adapter_client: FakeAdapterClient.new,
      run_record: FakeRunRecord.new,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      mode: :continuous,
      database_url: "postgres://example.test/checkpoint",
      pg: :fake_pg,
    )

    assert_equal ["postgres://example.test/checkpoint", :fake_pg], workload.invariant_sampler_args
  end

  def test_soak_mode_runs_until_stop_flag
    stop_flag = Load::Runner::InternalStopFlag.new
    workers_ready = Queue.new
    BarrierAction.reset!
    BarrierAction.ready_queue = workers_ready

    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: File.join(dir, "run"))
      runner = build_continuous_runner(run_record:, stop_flag:)
      thread = Thread.new { runner.run }

      workers_ready.pop
      stop_flag.trigger(:sigterm)

      assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }
      assert_equal true, run_record.read_run_json.dig("outcome", "aborted")
    end
  ensure
    BarrierAction.reset!
  end

  def test_internal_stop_flag_preserves_first_reason
    stop_flag = Load::Runner::InternalStopFlag.new

    stop_flag.trigger(:sigterm)
    stop_flag.trigger(:invariant_breach)

    assert_equal :sigterm, stop_flag.reason
  end

  def test_runner_aborts_after_three_consecutive_invariant_breaches
    workers_ready = Queue.new
    BarrierAction.reset!
    BarrierAction.ready_queue = workers_ready
    sampler = FakeInvariantSampler.new(
      [
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      ],
      first_sample_barrier: workers_ready,
    )

    run_record = FakeRunRecord.new
    runner = build_continuous_runner(run_record:, invariant_sampler: sampler)

    assert_equal Load::ExitCodes::ADAPTER_ERROR, Timeout.timeout(2.0) { runner.run }

    payload = run_record.read_run_json
    warnings = payload.fetch("warnings")
    assert_equal 3, warnings.length
    assert_includes warnings.last.fetch("message"), "open_count"
    assert_equal "invariant_breach", payload.dig("outcome", "error_code")
  ensure
    BarrierAction.reset!
  end

  def test_runner_enforce_policy_aborts_after_three_consecutive_breaches
    workers_ready = Queue.new
    BarrierAction.reset!
    BarrierAction.ready_queue = workers_ready
    sampler = FakeInvariantSampler.new(
      [
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      ],
      first_sample_barrier: workers_ready,
    )

    run_record = FakeRunRecord.new
    runner = build_continuous_runner(run_record:, invariant_sampler: sampler, invariant_policy: :enforce)

    assert_equal Load::ExitCodes::ADAPTER_ERROR, Timeout.timeout(2.0) { runner.run }

    payload = run_record.read_run_json
    warnings = payload.fetch("warnings")
    assert_equal 3, warnings.length
    assert_includes warnings.last.fetch("message"), "open_count"
    assert_equal "invariant_breach", payload.dig("outcome", "error_code")
  ensure
    BarrierAction.reset!
  end

  def test_runner_warn_policy_records_breaches_without_aborting
    stderr = StringIO.new
    started = Queue.new
    release = Queue.new
    samples = [
      invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
    ]
    sample_index = 0
    sampler = Object.new
    sampler.define_singleton_method(:call) do
      started << (sample_index += 1)
      release.pop
      samples.fetch(sample_index - 1)
    end

    run_record = FakeRunRecord.new
    stop_flag = Load::Runner::InternalStopFlag.new
    runner = build_continuous_runner(
      run_record:,
      stop_flag:,
      invariant_sampler: sampler,
      invariant_policy: :warn,
      stderr:,
    )
    thread = Thread.new { runner.run }

    3.times do |index|
      assert_equal index + 1, started.pop
      stop_flag.trigger(:sigterm) if index == 2
      release << true
    end
    stop_flag.trigger(:sigterm)

    assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }

    payload = run_record.read_run_json
    assert_equal 3, payload.fetch("warnings").length
    assert_equal 3, payload.fetch("invariant_samples").length
    assert_equal true, payload.dig("outcome", "aborted")
    assert_nil payload.dig("outcome", "error_code")
    assert_equal 3, stderr.string.lines.count { |line| line.start_with?("warning: invariant breach:") }
  ensure
    thread&.kill
    thread&.join
  end

  def test_runner_off_policy_skips_invariant_sampling
    stderr = StringIO.new
    workers_ready = Queue.new
    BarrierAction.reset!
    BarrierAction.ready_queue = workers_ready
    sampler_calls = 0
    sampler = Object.new
    sampler.define_singleton_method(:call) do
      sampler_calls += 1
      raise "off policy must not sample invariants"
    end

    run_record = FakeRunRecord.new
    stop_flag = Load::Runner::InternalStopFlag.new
    runner = build_continuous_runner(
      run_record:,
      stop_flag:,
      invariant_sampler: sampler,
      invariant_policy: :off,
      stderr:,
    )
    thread = Thread.new { runner.run }

    workers_ready.pop
    stop_flag.trigger(:sigterm)

    assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }
    assert_equal 0, sampler_calls
    assert_equal [], run_record.read_run_json.fetch("warnings")
    assert_equal [], run_record.read_run_json.fetch("invariant_samples")
    assert_equal "", stderr.string
  ensure
    thread&.kill
    thread&.join
    BarrierAction.reset!
  end

  def test_runner_off_policy_runs_without_database_url
    run_record = FakeRunRecord.new
    workers_ready = Queue.new
    BarrierAction.reset!
    BarrierAction.ready_queue = workers_ready
    stop_flag = Load::Runner::InternalStopFlag.new
    runner = build_continuous_runner(
      run_record:,
      stop_flag:,
      invariant_sampler: nil,
      invariant_policy: :off,
      database_url: nil,
    )
    thread = Thread.new { runner.run }

    workers_ready.pop
    stop_flag.trigger(:sigterm)

    assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }
    assert_equal [], run_record.read_run_json.fetch("warnings")
    assert_equal [], run_record.read_run_json.fetch("invariant_samples")
  ensure
    thread&.kill
    thread&.join
    BarrierAction.reset!
  end

  def test_runner_reports_sampler_failure_as_controlled_error
    run_record = FakeRunRecord.new
    stop_flag = Load::Runner::InternalStopFlag.new
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
      mode: :continuous,
      invariant_sampler: RaisingInvariantSampler.new(stop_flag:),
      invariant_sample_interval_seconds: 0.001,
      database_url: nil,
    )

    exit_code = Timeout.timeout(2.0) { runner.run }

    assert_equal Load::ExitCodes::ADAPTER_ERROR, exit_code
    assert_equal true, run_record.outcome.fetch(:aborted)
    assert_equal "invariant_sampler_failed", run_record.outcome.fetch(:error_code)
  end

  def test_runner_records_invariant_breach_before_first_successful_request
    sampler = FakeInvariantSampler.new(
      [
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      ],
    )
    run_record = FakeRunRecord.new
    runner = Load::Runner.new(
      workload: NeverFinishingWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      mode: :continuous,
      invariant_sampler: sampler,
      invariant_sample_interval_seconds: 0.001,
      database_url: nil,
    )

    exit_code = Timeout.timeout(2.5) { runner.run }

    assert_equal Load::ExitCodes::ADAPTER_ERROR, exit_code
    assert_equal 0, run_record.outcome.fetch(:requests_total)
    assert_equal "invariant_breach", run_record.outcome.fetch(:error_code)
  end

  def test_runner_does_not_abort_when_breach_recovers
    stop_flag = Load::Runner::InternalStopFlag.new
    workers_ready = Queue.new
    BarrierAction.reset!
    BarrierAction.ready_queue = workers_ready
    sampler = FakeInvariantSampler.new(
      [
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 35_000, total_count: 100_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 100, total_count: 10_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 35_000, total_count: 100_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      ],
      first_sample_barrier: workers_ready,
    )

    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: File.join(dir, "run"))
      runner = build_continuous_runner(run_record:, stop_flag:, invariant_sampler: sampler)
      thread = Thread.new { runner.run }

      sampler.wait_until_drained
      stop_flag.trigger(:sigterm)

      assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }
      assert_equal 3, run_record.read_run_json.fetch("warnings").length
      assert_nil run_record.read_run_json.dig("outcome", "error_code")
    end
  ensure
    BarrierAction.reset!
  end

  def test_runner_waits_one_interval_before_first_invariant_sample_and_interrupts_shutdown
    run_record = FakeRunRecord.new
    stop_flag = Load::Runner::InternalStopFlag.new
    clock = AdvancingClock.new(Time.utc(2026, 4, 25, 0, 0, 0))
    sleeper = BlockingInvariantSleeper.new(clock:, blocked_interval: 60.0)
    sampler = RecordingInvariantSampler.new(clock:)
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: -> { clock.now },
      sleeper:,
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
      mode: :continuous,
      invariant_sampler: sampler,
      invariant_sample_interval_seconds: 60.0,
      database_url: nil,
    )

    thread = Thread.new { runner.run }
    sleeper.wait_until_interval_sleep
    assert_equal [], sampler.call_times

    stop_flag.trigger(:sigterm)

    assert_equal Load::ExitCodes::SUCCESS, Timeout.timeout(2.0) { thread.value }
    assert_equal true, run_record.outcome.fetch(:aborted)
    assert_equal [60.0], sleeper.interval_calls
  ensure
    thread&.kill
    thread&.join
  end

  def test_stop_invariant_thread_ignores_thread_error_when_thread_exits_during_shutdown
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record: FakeRunRecord.new,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      mode: :continuous,
      invariant_sampler: FakeInvariantSampler.new([]),
      database_url: nil,
    )
    thread = ExitingInvariantThread.new

    runner.send(:mark_invariant_thread_sleeping, true)
    runner.send(:stop_invariant_thread, thread)

    assert_equal 1, thread.raise_calls
    assert_equal 1, thread.join_calls
  end

  def test_invariant_check_reports_min_and_max_breaches
    check = Load::Runner::InvariantCheck.new("total_count", 250, 300, 200)

    assert_equal [
      "total_count 250 is below min 300",
      "total_count 250 is above max 200",
    ], check.breaches
    assert_equal true, check.breach?
  end

  def test_invariant_check_with_nil_min_and_max_never_breaches
    check = Load::Runner::InvariantCheck.new("total_count", 250, nil, nil)

    assert_equal [], check.breaches
    assert_equal false, check.breach?
  end

  def test_invariant_check_actual_equal_to_min_does_not_breach
    check = Load::Runner::InvariantCheck.new("total_count", 250, 250, 300)

    assert_equal [], check.breaches
  end

  def test_invariant_sample_with_empty_checks_is_healthy
    sample = Load::Runner::InvariantSample.new([])

    assert_equal true, sample.healthy?
    assert_equal false, sample.breach?
  end

  def test_invariant_sample_aggregates_check_records_for_warning_and_run_json
    sample = Load::Runner::InvariantSample.new(
      [
        Load::Runner::InvariantCheck.new("open_count", 100, 300, nil),
        Load::Runner::InvariantCheck.new("total_count", 1000, 800, 1200),
      ],
    )

    assert_equal true, sample.breach?
    assert_equal 2, sample.to_warning.fetch(:checks).length
    assert_equal 2, sample.to_record(sampled_at: Time.utc(2026, 4, 25, 0, 0, 0)).fetch(:checks).length
  end

  def test_runner_samples_diverse_ids_for_mixed_write_actions
    run_record = FakeRunRecord.new
    stop_flag = Load::Runner::InternalStopFlag.new
    http = RecordingRequestHttp.new(stop_flag:, stop_after: 300)
    runner = Load::Runner.new(
      workload: MixedWriteWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: http,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )

    exit_code = Timeout.timeout(2.0) { runner.run }

    assert_equal Load::ExitCodes::SUCCESS, exit_code
    assert_operator http.create_user_ids.uniq.length, :>=, 20
    assert_operator http.delete_user_ids.uniq.length, :>=, 20
    assert_operator http.closed_todo_ids.uniq.length, :>=, 20
  end

  def test_runner_persists_invariant_samples_in_run_record
    run_record = FakeRunRecord.new
    stop_flag = Load::Runner::InternalStopFlag.new
    clock = AdvancingClock.new(Time.utc(2026, 4, 25, 0, 0, 0))
    sampler = PersistedSamplesInvariantSampler.new(
      stop_flag:,
      samples: [
        invariant_sample(open_count: 35_000, total_count: 100_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
        invariant_sample(open_count: 20_000, total_count: 100_000, open_floor: 30_000, total_floor: 80_000, total_ceiling: 200_000),
      ],
    )
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds); Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
      mode: :continuous,
      invariant_sampler: sampler,
      invariant_sample_interval_seconds: 0.001,
      database_url: nil,
    )

    exit_code = Timeout.timeout(2.0) { runner.run }

    assert_equal Load::ExitCodes::SUCCESS, exit_code
    samples = run_record.read_run_json.fetch("invariant_samples")
    assert_equal 2, samples.length
    assert_equal false, samples.first.fetch("breach")
    assert_equal true, samples.last.fetch("breach")
    assert_equal 1, run_record.read_run_json.fetch("warnings").length
  end

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
    clock = AdvancingClock.new(Time.utc(2026, 4, 24, 0, 0, 0))
    sleeper = ->(*) { stop_flag.trigger(:sigint) }
    runner = Load::Runner.new(
      workload: FakeWorkload.new,
      adapter_client: adapter,
      run_record:,
      clock: -> { clock.now },
      sleeper:,
      http: FakeHttp.new,
      stop_flag:,
    )

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

  def test_runner_builds_one_client_per_worker
    run_record = FakeRunRecord.new
    stop_flag = StopFlag.new
    stop_flag.trigger(:sigterm)
    runner = Load::Runner.new(
      workload: MultiWorkerWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) {},
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
    )
    calls = []
    client_singleton = Load::Client.singleton_class
    original_new = Load::Client.method(:new)

    client_singleton.send(:define_method, :new) do |*args, **kwargs|
      calls << { args:, kwargs: }
      original_new.call(*args, **kwargs)
    end

    runner.run

    assert_equal 3, calls.length
  ensure
    client_singleton.send(:remove_method, :new)
    client_singleton.send(:define_method, :new, original_new)
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
    assert_equal 2, payload.fetch(:schema_version)
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

  def test_runner_initial_state_uses_schema_version_2
    run_record = FakeRunRecord.new
    runner = Load::Runner.new(
      workload: MetricsWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
    )

    assert_equal 2, runner.send(:initial_state).fetch(:schema_version)
  end

  def test_workload_invariant_sampler_defaults_to_nil
    assert_nil Load::Workload.new.invariant_sampler(database_url: "postgres://example.test/db", pg: Object.new)
  end

  private

  def fake_clock
    -> { Time.now.utc }
  end

  def invariant_sample(open_count:, total_count:, open_floor:, total_floor:, total_ceiling:)
    Load::Runner::InvariantSample.new(
      [
        Load::Runner::InvariantCheck.new("open_count", open_count, open_floor, nil),
        Load::Runner::InvariantCheck.new("total_count", total_count, total_floor, total_ceiling),
      ],
    )
  end

  def build_continuous_runner(run_record:, stop_flag: Load::Runner::InternalStopFlag.new, invariant_sampler: :default_sampler, invariant_policy: :enforce, stderr: StringIO.new, database_url: nil)
    invariant_sampler = FakeInvariantSampler.new([]) if invariant_sampler == :default_sampler
    Load::Runner.new(
      workload: BarrierWorkload.new,
      adapter_client: FakeAdapterClient.new,
      run_record:,
      clock: fake_clock,
      sleeper: ->(*) { Thread.pass },
      http: FakeHttp.new,
      readiness_path: nil,
      startup_grace_seconds: 0.0,
      stop_flag:,
      mode: :continuous,
      invariant_sampler:,
      invariant_sample_interval_seconds: 0.001,
      database_url:,
      invariant_policy:,
      stderr:,
    )
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

    def read_run_json
      JSON.parse(JSON.generate(@payload))
    end
  end

  class FakeAdapterClient
    attr_reader :stop_calls, :describe_calls, :adapter_bin, :reset_state_workloads

    def initialize(start_response: { "ok" => true, "pid" => 123, "base_url" => "http://127.0.0.1:3999" }, describe_response: { "name" => "fake-adapter", "framework" => "ruby", "runtime" => "test" }, describe_error: nil, prepare_error: nil, reset_state_response: {}, adapter_bin: nil, stop_error: nil, call_order: nil)
      @start_response = start_response
      @describe_response = describe_response
      @describe_error = describe_error
      @prepare_error = prepare_error
      @reset_state_response = reset_state_response
      @adapter_bin = adapter_bin
      @stop_error = stop_error
      @call_order = call_order
      @stop_calls = 0
      @describe_calls = 0
      @reset_state_workloads = []
    end

    def describe
      @call_order << :describe if @call_order
      @describe_calls += 1
      raise @describe_error if @describe_error

      @describe_response
    end

    def prepare(app_root:)
      @call_order << :prepare if @call_order
      raise @prepare_error if @prepare_error

      true
    end

    def reset_state(app_root:, workload:, scale:)
      @call_order << :reset_state if @call_order
      @reset_state_workloads << workload
      @reset_state_response
    end

    def start(app_root:)
      @call_order << :start if @call_order
      @start_response
    end

    def stop(pid:)
      @call_order << :stop if @call_order
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

  class ReadinessLoggingHttp < FakeHttp
    def initialize(call_order:)
      super(always_refuse: false)
      @call_order = call_order
    end

    def request(*)
      @call_order << :readiness
      super
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
      Load::Scale.new(rows_per_table: 1, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(FastAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 1.0, rate_limit: :unlimited, seed: 42)
    end
  end

  class VerifierOrderWorkload < FakeWorkload
    def actions
      [Load::ActionEntry.new(VerifierOrderAction, 1)]
    end
  end

  class VerifierOrderAction
    Response = Struct.new(:code)

    class << self
      attr_accessor :call_order, :stop_flag
    end

    def self.reset!
      @call_order = nil
      @stop_flag = nil
    end

    def initialize(rng:, ctx:, client:)
    end

    def name
      :verifier_order
    end

    def call
      self.class.call_order << :worker
      self.class.stop_flag.trigger(:request_seen)
      Response.new("200")
    end
  end

  class BarrierWorkload < Load::Workload
    def name
      "barrier-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 100_000, extra: { open_fraction: 0.6 }, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(BarrierAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 1.0, rate_limit: :unlimited, seed: 42)
    end
  end

  BarrierAction = Class.new(Load::Action) do
    BarrierResponse = Struct.new(:code)

    @ready_queue = nil
    @signaled = false

    class << self
      attr_accessor :ready_queue

      def reset!
        @ready_queue = nil
        @signaled = false
      end

      def signal_once
        return unless @ready_queue
        return if @signaled

        @signaled = true
        @ready_queue << :ready
      end
    end

    def name
      :barrier_action
    end

    def call
      self.class.signal_once
      BarrierResponse.new("200")
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
      Load::Scale.new(rows_per_table: 1, seed: 42)
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
      Load::Scale.new(rows_per_table: 1, seed: 42)
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
      Load::Scale.new(rows_per_table: 1, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(SeedRecordingAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.1, rate_limit: :unlimited, seed: 42)
    end
  end

  class RecordingSamplerWorkload < MetricsWorkload
    attr_reader :invariant_sampler_args

    def invariant_sampler(database_url:, pg:)
      @invariant_sampler_args = [database_url, pg]
      FakeInvariantSampler.new([])
    end
  end

  class MultiWorkerWorkload < Load::Workload
    def name
      "multi-worker-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(FastAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 3, duration_seconds: 0.01, rate_limit: :unlimited, seed: 42)
    end
  end

  class HungRequestWorkload < Load::Workload
    def name
      "hung-request-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, seed: 42)
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
      Load::Scale.new(rows_per_table: 1, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(HttpClientAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.01, rate_limit: :unlimited, seed: 42)
    end
  end

  class NeverFinishingWorkload < Load::Workload
    def name
      "never-finishing-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(NeverFinishingAction, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0.01, rate_limit: :unlimited, seed: 42)
    end
  end

  NeverFinishingAction = Class.new(Load::Action) do
    def name
      :never_finishing_action
    end

    def call
      Queue.new.pop
    end
  end

  class FakeInvariantSampler
    def initialize(samples, first_sample_barrier: nil)
      @samples = samples.dup
      @first_sample_barrier = first_sample_barrier
      @first_sample = true
      @drained = Queue.new
      @mutex = Mutex.new
    end

    def call
      barrier = nil
      sample = nil

      @mutex.synchronize do
        barrier = @first_sample_barrier if @first_sample
        @first_sample = false
        sample = @samples.shift || Load::Runner::InvariantSample.new(
          [
            Load::Runner::InvariantCheck.new("open_count", 35_000, 30_000, nil),
            Load::Runner::InvariantCheck.new("total_count", 100_000, 80_000, 200_000),
          ],
        )
        @drained << true if @samples.empty?
      end

      barrier&.pop
      sample
    end

    def wait_until_drained
      @drained.pop
    end
  end

  class RaisingInvariantSampler
    def initialize(stop_flag:)
      @stop_flag = stop_flag
    end

    def call
      @stop_flag.trigger(:invariant_sampler_failed)
      raise "sampler blew up"
    end
  end

  class RecordingInvariantSampler
    attr_reader :call_times

    def initialize(clock:)
      @clock = clock
      @call_times = []
    end

    def call
      @call_times << @clock.now
      Load::Runner::InvariantSample.new(
        [
          Load::Runner::InvariantCheck.new("open_count", 35_000, 30_000, nil),
          Load::Runner::InvariantCheck.new("total_count", 100_000, 80_000, 200_000),
        ],
      )
    end
  end

  class BlockingInvariantSleeper
    attr_reader :interval_calls

    def initialize(clock:, blocked_interval:)
      @clock = clock
      @blocked_interval = blocked_interval
      @interval_sleep_started = Queue.new
      @interval_calls = []
    end

    def call(seconds)
      if seconds == @blocked_interval
        @interval_calls << seconds
        @interval_sleep_started << true
        Queue.new.pop
      else
        @clock.advance_by(seconds)
        Thread.pass
      end
    end

    def wait_until_interval_sleep
      @interval_sleep_started.pop
    end
  end

  class ExitingInvariantThread
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
      Kernel.raise ThreadError, "killed thread"
    end

    def join(*)
      @join_calls += 1
      true
    end
  end

  class RecordingRequestHttp < FakeHttp
    attr_reader :create_user_ids, :delete_user_ids, :closed_todo_ids

    def initialize(stop_flag:, stop_after:)
      super(always_refuse: false)
      @stop_flag = stop_flag
      @stop_after = stop_after
      @request_count = 0
      @create_user_ids = []
      @delete_user_ids = []
      @closed_todo_ids = []
    end

    def request(request)
      @request_count += 1
      record_request(request)
      @stop_flag.trigger(:sigterm) if @request_count >= @stop_after
      Response.new("200")
    end

    private

    def record_request(request)
      case request.path
      when "/api/todos"
        @create_user_ids << JSON.parse(request.body).fetch("user_id")
      when "/api/todos/completed"
        @delete_user_ids << JSON.parse(request.body).fetch("user_id")
      when %r{\A/api/todos/(\d+)\z}
        @closed_todo_ids << Regexp.last_match(1).to_i
      end
    end
  end

  class PersistedSamplesInvariantSampler
    def initialize(stop_flag:, samples:)
      @stop_flag = stop_flag
      @samples = samples.dup
    end

    def call
      sample = @samples.shift
      @stop_flag.trigger(:sigterm) if @samples.empty?
      sample
    end
  end

  class MixedWriteWorkload < Load::Workload
    def name
      "mixed-write-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 100, extra: { open_fraction: 0.6 }, seed: 42)
    end

    def actions
      [
        Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::CreateTodo, 1),
        Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::CloseTodo, 1),
        Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos, 1),
      ]
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 10, rate_limit: :unlimited, seed: 42)
    end
  end
end
