# ABOUTME: Owns the mutable run payload and persists it to the run record.
# ABOUTME: Encapsulates initial state, window pinning, warnings, samples, and final outcome writes.
require "thread"

module Load
  class RunState
    def initialize(run_record:, workload:, adapter_bin:, app_root:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, workload_file:)
      @run_record = run_record
      @mutex = Mutex.new
      @window_started = false
      @state = initial_state(
        run_record:,
        workload:,
        adapter_bin:,
        app_root:,
        readiness_path:,
        startup_grace_seconds:,
        metrics_interval_seconds:,
        workload_file:,
      )
    end

    def write_initial
      @mutex.synchronize do
        write_current_locked
      end
    end

    def merge(fragment)
      @mutex.synchronize do
        @state = deep_merge(@state, deep_copy(fragment))
        write_current_locked
      end
    end

    def pin_window_start(now:)
      @mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: now })
        write_current_locked
      end
    end

    def append_warning(payload)
      @mutex.synchronize do
        warnings = @state.fetch(:warnings).dup
        warnings << deep_copy(payload)
        @state = deep_merge(@state, warnings:)
        write_current_locked
      end
    end

    def append_invariant_sample(sampled_at:, breach:, breaches:, checks:)
      @mutex.synchronize do
        invariant_samples = @state.fetch(:invariant_samples).dup
        invariant_samples << {
          sampled_at:,
          breach:,
          breaches: deep_copy(breaches),
          checks: deep_copy(checks),
        }
        @state = deep_merge(@state, invariant_samples:)
        write_current_locked
      end
    end

    def finish(now:, request_totals:, aborted:, error_code: nil)
      @mutex.synchronize do
        @state = deep_merge(
          @state,
          window: { end_ts: now },
          outcome: outcome_payload(request_totals:, aborted:, error_code:),
        )
        write_current_locked
      end
    end

    def outcome_payload(request_totals:, aborted:, error_code: nil)
      {
        requests_total: request_totals.fetch(:total),
        requests_ok: request_totals.fetch(:ok),
        requests_error: request_totals.fetch(:error),
        aborted:,
        error_code:,
      }.compact
    end

    def snapshot
      @mutex.synchronize do
        deep_copy(@state)
      end
    end

    def window_started?
      @mutex.synchronize do
        @window_started
      end
    end

    private

    def initial_state(run_record:, workload:, adapter_bin:, app_root:, readiness_path:, startup_grace_seconds:, metrics_interval_seconds:, workload_file:)
      {
        run_id: File.basename(run_record.run_dir),
        schema_version: 2,
        workload: {
          name: workload.name,
          file: workload_file,
          scale: workload.scale.to_h,
          load_plan: workload.load_plan.to_h,
          actions: workload.actions.map { |entry| { class: entry.action_class.name, weight: entry.weight } },
        },
        adapter: {
          describe: nil,
          bin: adapter_bin,
          app_root: app_root,
          base_url: nil,
          pid: nil,
        },
        window: {
          start_ts: nil,
          end_ts: nil,
          readiness: {
            path: readiness_path,
            probe_duration_ms: nil,
            probe_attempts: nil,
          },
          startup_grace_seconds: startup_grace_seconds,
          metrics_interval_seconds: metrics_interval_seconds,
        },
        outcome: outcome_payload(request_totals: { total: 0, ok: 0, error: 0 }, aborted: false),
        query_ids: [],
        warnings: [],
        invariant_samples: [],
      }
    end

    def write_current_locked
      @run_record.write_run(deep_copy(@state))
    end

    def deep_merge(left, right)
      left.merge(right) do |_, left_value, right_value|
        if left_value.is_a?(Hash) && right_value.is_a?(Hash)
          deep_merge(left_value, right_value)
        else
          right_value
        end
      end
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, inner_value), copy| copy[key] = deep_copy(inner_value) }
      when Array
        value.map { |inner_value| deep_copy(inner_value) }
      else
        value
      end
    end
  end
end
