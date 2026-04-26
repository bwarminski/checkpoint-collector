# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "pg"
require "thread"
require "time"

module Load
  class Runner
    DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS = 60.0
    Runtime = Data.define(:clock, :sleeper, :http, :stop_flag)
    Settings = Data.define(:readiness_path, :startup_grace_seconds, :metrics_interval_seconds, :workload_file, :app_root, :adapter_bin)
    attr_reader :run_state

    InvariantCheck = Data.define(:name, :actual, :min, :max) do
      def breaches
        [].tap do |messages|
          messages << "#{name} #{actual} is below min #{min}" if !min.nil? && actual < min
          messages << "#{name} #{actual} is above max #{max}" if !max.nil? && actual > max
        end
      end

      def breach?
        !breaches.empty?
      end

      def to_record
        { name:, actual:, min:, max:, breach: breach?, breaches: }
      end
    end

    InvariantSample = Data.define(:checks) do
      def breaches
        checks.flat_map(&:breaches)
      end

      def breach?
        !breaches.empty?
      end

      def healthy?
        !breach?
      end

      def to_warning
        { type: "invariant_breach", message: breaches.join("; "), checks: checks.map(&:to_record) }
      end

      def to_record(sampled_at:)
        { sampled_at:, checks: checks.map(&:to_record), breach: breach?, breaches: }
      end
    end

    def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:, http: Net::HTTP, readiness_path: "/up", startup_grace_seconds: 15, metrics_interval_seconds: 5, workload_file: nil, app_root: nil, adapter_bin: nil, stop_flag: nil, verifier: nil, mode: :finite, invariant_policy: :enforce, invariant_sampler: nil, invariant_sample_interval_seconds: DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS, database_url: ENV["DATABASE_URL"], pg: PG, stderr: $stderr)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @runtime = Runtime.new(clock, sleeper, http, stop_flag || InternalStopFlag.new)
      @settings = Settings.new(readiness_path, startup_grace_seconds, metrics_interval_seconds, workload_file, app_root, adapter_bin)
      @verifier = verifier
      @mode = mode
      @stderr = stderr
      sampler = if invariant_policy == :off
        invariant_sampler
      else
        invariant_sampler || @workload.invariant_sampler(database_url:, pg:)
      end
      if @mode == :continuous && invariant_policy != :off && sampler.nil?
        raise AdapterClient::AdapterError, "continuous mode requires the workload to provide an invariant sampler"
      end
      @run_state = Load::RunState.new(
        run_record:,
        workload:,
        adapter_bin: @settings.adapter_bin || @adapter_client.adapter_bin,
        app_root: @settings.app_root,
        readiness_path: @settings.readiness_path,
        startup_grace_seconds: @settings.startup_grace_seconds,
        metrics_interval_seconds: @settings.metrics_interval_seconds,
        workload_file: workload_file,
      )
      @invariant_monitor = Load::InvariantMonitor.new(
        sampler: sampler,
        policy: invariant_policy,
        interval_seconds: invariant_sample_interval_seconds,
        stop_flag: @runtime.stop_flag,
        sleeper: @runtime.sleeper,
        on_sample: ->(sample) { @run_state.append_invariant_sample(**sample.to_record(sampled_at: current_time)) },
        on_warning: ->(warning) { @run_state.append_warning(warning) },
        on_breach_stop: ->(reason) { trigger_stop(reason) },
        stderr: @stderr,
      )
    end

    def run
      request_totals = { total: 0, ok: 0, error: 0 }
      begin
        @run_state.write_initial
        adapter_describe = @adapter_client.describe
        validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
        @run_state.merge(adapter: {
          describe: adapter_describe,
          bin: @settings.adapter_bin || @adapter_client.adapter_bin,
          app_root: @settings.app_root,
        })

        @adapter_client.prepare(app_root: @settings.app_root)
        reset_state = @adapter_client.reset_state(app_root: @settings.app_root, workload: @workload.name, scale: @workload.scale)
        @run_state.merge(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if reset_state.is_a?(Hash) && reset_state["query_ids"]

        start_response = @adapter_client.start(app_root: @settings.app_root)
        validate_adapter_response!(start_response, %w[pid base_url], "start")
        @run_state.merge(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

        probe_readiness(start_response.fetch("base_url"))
        verify_fixture(base_url: start_response.fetch("base_url"))
        request_totals = run_execution(start_response.fetch("base_url"))

        result = finish_run(request_totals)
      rescue Load::InvariantMonitor::Failure
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "invariant_sampler_failed"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::FixtureVerifier::VerificationError => error
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "fixture_verification_failed").merge(error_message: error.message))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue AdapterClient::AdapterError
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "adapter_error"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::ReadinessGate::Timeout
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "readiness_timeout"))
        result = Load::ExitCodes::ADAPTER_ERROR
      ensure
        result = stop_adapter_safely(result, request_totals)
      end

      result
    end

    private

    def verify_fixture(base_url:)
      return unless @verifier

      @verifier.call(base_url:)
    end

    def probe_readiness(base_url)
      @run_state.merge(
        window: {
          readiness: Load::ReadinessGate.new(
            base_url:,
            readiness_path: @settings.readiness_path,
            startup_grace_seconds: @settings.startup_grace_seconds,
            clock: @runtime.clock,
            sleeper: @runtime.sleeper,
            http: @runtime.http,
          ).call,
        },
      )
    end

    def run_execution(base_url)
      execution = nil
      invariant_thread = nil
      request_totals = { total: 0, ok: 0, error: 0 }

      begin
        execution = Load::LoadExecution.new(
          workload: @workload,
          base_url:,
          runtime: @runtime,
          metrics_interval_seconds: @settings.metrics_interval_seconds,
          run_record: @run_record,
          on_first_success: -> { @run_state.pin_window_start(now: current_time) },
        )
        invariant_thread = @mode == :continuous ? @invariant_monitor.start : nil
        request_totals = execution.run(mode: @mode, duration_seconds: @workload.load_plan.duration_seconds)
      ensure
        request_totals = execution.request_totals if execution
        @invariant_monitor.stop(invariant_thread)
      end

      request_totals
    end

    def trigger_stop(reason)
      return unless @runtime.stop_flag.respond_to?(:trigger)

      @runtime.stop_flag.trigger(reason)
    end

    def finish_run(request_totals)
      if stop_reason == :invariant_breach
        @run_state.finish(now: current_time, request_totals:, aborted: true, error_code: "invariant_breach")
        return Load::ExitCodes::ADAPTER_ERROR
      end

      if @run_state.window_started?
        @run_state.finish(now: current_time, request_totals:, aborted: stop_aborted?)
        return final_exit_code
      end

      @run_state.finish(now: current_time, request_totals:, aborted: true, error_code: "no_successful_requests")
      Load::ExitCodes::NO_SUCCESSFUL_REQUESTS
    end

    def final_exit_code
      return Load::ExitCodes::ADAPTER_ERROR if stop_reason == :invariant_breach

      Load::ExitCodes::SUCCESS
    end

    def stop_aborted?
      %i[sigint sigterm].include?(stop_reason)
    end

    def stop_reason
      return nil unless @runtime.stop_flag.respond_to?(:reason)

      @runtime.stop_flag.reason
    end

    def current_time
      @runtime.clock.call
    end

    def workload_file
      return @settings.workload_file if @settings.workload_file

      path = @workload.class.instance_method(:name).source_location&.first
      return nil unless path

      expanded = File.expand_path(path)
      cwd = "#{Dir.pwd}/"
      expanded.start_with?(cwd) ? expanded.delete_prefix(cwd) : expanded
    end

    def stop_adapter_safely(result, request_totals)
      pid = @run_state.snapshot.dig(:adapter, :pid)
      return result unless pid

      @adapter_client.stop(pid:)
      result
    rescue AdapterClient::AdapterError
      if result.nil? || result == Load::ExitCodes::SUCCESS
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals:, aborted: true, error_code: "adapter_error"))
        return Load::ExitCodes::ADAPTER_ERROR
      end

      result
    end

    def validate_adapter_response!(response, required_keys, response_name)
      raise AdapterClient::AdapterError, "invalid adapter #{response_name} response" unless response.is_a?(Hash)

      required_keys.each { |key| response.fetch(key) }
    rescue KeyError
      raise AdapterClient::AdapterError, "invalid adapter #{response_name} response"
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

    class InternalStopFlag
      attr_reader :reason

      def initialize
        @reason = nil
      end

      def trigger(reason)
        @reason ||= reason
      end

      def call
        !@reason.nil?
      end
    end

  end
end
