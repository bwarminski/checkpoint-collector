# ABOUTME: Verifies run-state mutation and persistence for load runs.
# ABOUTME: Covers initial payload shape, window pinning, warnings, samples, outcome, and snapshot isolation.
require "tmpdir"
require_relative "test_helper"

class RunStateTest < Minitest::Test
  def test_initial_write_matches_runner_contract
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)
      state = build_state(run_record:)

      state.write_initial

      payload = run_record.read_run_json
      assert_equal "fixture-workload", payload.dig("workload", "name")
      assert_equal "/up", payload.dig("window", "readiness", "path")
      assert_equal [], payload.fetch("warnings")
      assert_equal [], payload.fetch("invariant_samples")
    end
  end

  def test_pin_window_start_only_writes_once
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)
      state = build_state(run_record:)

      state.write_initial
      state.pin_window_start(now: Time.utc(2026, 4, 25, 12, 0, 0))
      state.pin_window_start(now: Time.utc(2026, 4, 25, 12, 5, 0))

      assert_equal "2026-04-25 12:00:00 UTC", run_record.read_run_json.dig("window", "start_ts")
    end
  end

  def test_append_warning_and_sample_persist_into_run_json
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)
      state = build_state(run_record:)

      state.write_initial
      state.append_warning(type: "invariant_breach", message: "too low")
      state.append_invariant_sample(
        sampled_at: "2026-04-25 12:00:00 UTC",
        breach: true,
        breaches: ["too low"],
        checks: [],
      )

      payload = run_record.read_run_json
      assert_equal 1, payload.fetch("warnings").length
      assert_equal 1, payload.fetch("invariant_samples").length
    end
  end

  def test_finish_writes_request_totals_and_error_code
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)
      state = build_state(run_record:)

      state.write_initial
      state.finish(
        now: Time.utc(2026, 4, 25, 12, 1, 0),
        request_totals: { total: 10, ok: 9, error: 1 },
        aborted: true,
        error_code: "adapter_error",
      )

      payload = run_record.read_run_json
      assert_equal 10, payload.dig("outcome", "requests_total")
      assert_equal "adapter_error", payload.dig("outcome", "error_code")
    end
  end

  def test_snapshot_returns_an_isolated_copy
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)
      state = build_state(run_record:)

      state.write_initial

      snapshot = state.snapshot
      snapshot.fetch(:warnings) << "mutation"

      assert_equal [], state.snapshot.fetch(:warnings)
    end
  end

  private

  def build_state(run_record:)
    Load::RunState.new(
      run_record:,
      workload: build_workload,
      adapter_bin: "adapters/rails/bin/bench-adapter",
      app_root: "/tmp/demo",
      readiness_path: "/up",
      startup_grace_seconds: 15.0,
      metrics_interval_seconds: 5.0,
      workload_file: "workloads/missing_index_todos/workload",
    )
  end

  def build_workload
    Class.new(Load::Workload) do
      def name = "fixture-workload"
      def scale = Load::Scale.new(rows_per_table: 1, seed: 42)
      def actions = [Load::ActionEntry.new(action_class: RunStateAction, weight: 1)]
      def load_plan = Load::LoadPlan.new(workers: 1, duration_seconds: 0, rate_limit: :unlimited, seed: 42)
    end.new
  end

  class RunStateAction
  end
end
