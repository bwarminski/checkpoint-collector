# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "pg"
require "thread"
require "time"

module Load
  class Runner
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0
    CONTINUOUS_POLL_SECONDS = 0.1
    DEFAULT_INVARIANT_SAMPLE_INTERVAL_SECONDS = 60.0
    Runtime = Data.define(:clock, :sleeper, :http, :stop_flag)
    Settings = Data.define(:readiness_path, :startup_grace_seconds, :metrics_interval_seconds, :workload_file, :app_root, :adapter_bin)
    InvariantState = Struct.new(:policy, :sampler, :interval_seconds, :consecutive_breaches, :thread_sleeping, :failure, keyword_init: true)
    attr_reader :run_state

    MetricsSink = Data.define(:run_record) do
      def <<(line)
        run_record.append_metrics(line)
      end
    end

    class TrackingBuffer < Load::Metrics::Buffer
      def initialize(runner)
        super()
        @runner = runner
        @started = false
        @request_totals = { total: 0, ok: 0, error: 0 }
        @runner.send(:register_tracking_buffer, self)
      end

      def record_ok(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:ok] += 1
        return if @started

        @started = true
        @runner.run_state.pin_window_start(now: @runner.send(:current_time))
      end

      def record_error(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:error] += 1
      end

      def request_totals
        @request_totals.dup
      end
    end

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

    class InvariantSamplerFailure < StandardError; end
    class InvariantSamplerShutdown < StandardError; end

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
      @invariants = InvariantState.new(
        policy: invariant_policy,
        sampler: sampler,
        interval_seconds: invariant_sample_interval_seconds,
        consecutive_breaches: 0,
        thread_sleeping: false,
        failure: nil,
      )
      @invariant_mutex = Mutex.new
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
      @tracking_buffers = []
    end

    def run
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
        start_workers(start_response.fetch("base_url"))

        result = finish_run
      rescue InvariantSamplerFailure
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals: aggregate_request_totals, aborted: true, error_code: "invariant_sampler_failed"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::FixtureVerifier::VerificationError => error
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals: aggregate_request_totals, aborted: true, error_code: "fixture_verification_failed").merge(error_message: error.message))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue AdapterClient::AdapterError
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals: aggregate_request_totals, aborted: true, error_code: "adapter_error"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::ReadinessGate::Timeout
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals: aggregate_request_totals, aborted: true, error_code: "readiness_timeout"))
        result = Load::ExitCodes::ADAPTER_ERROR
      ensure
        result = stop_adapter_safely(result)
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

    def start_workers(base_url)
      plan = @workload.load_plan
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @runtime.clock, sleeper: @runtime.sleeper)
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed
      workers = Array.new(plan.workers) do |index|
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries: entries, rng: Random.new(seed + index)),
          buffer: tracking_buffer,
          client: Load::Client.new(base_url: base_url, http: @runtime.http),
          ctx: { base_url: base_url, scale: @workload.scale },
          rng: Random.new(seed + index),
          rate_limiter: rate_limiter,
          stop_flag: @runtime.stop_flag,
        )
      end

      reporter = Load::Reporter.new(
        workers:,
        interval_seconds: @settings.metrics_interval_seconds,
        sink: MetricsSink.new(@run_record),
        clock: @runtime.clock,
        sleeper: @runtime.sleeper,
      )
      reporter.start
      threads = workers.map { |worker| Thread.new { worker.run } }
      invariant_thread = start_invariant_thread
      execute_window(plan.duration_seconds)
    ensure
      stop_invariant_thread(invariant_thread)
      drain_workers(threads)
      reporter.stop
      raise_invariant_failure_if_present
    end

    def execute_window(duration_seconds)
      if @mode == :continuous
        wait_for_stop_signal
      else
        wait_for_window_end(duration_seconds)
      end
    end

    def wait_for_window_end(duration_seconds)
      deadline = current_time + duration_seconds

      until @runtime.stop_flag.call
        remaining = deadline - current_time
        if remaining <= 0
          @runtime.stop_flag.trigger(:timeout) if @runtime.stop_flag.respond_to?(:trigger)
          break
        end

        Thread.pass
        next if @runtime.stop_flag.call

        remaining = deadline - current_time
        next if remaining <= 0

        @runtime.sleeper.call([1.0, remaining].min)
      end
    end

    def wait_for_stop_signal
      until @runtime.stop_flag.call
        Thread.pass
        @runtime.sleeper.call(CONTINUOUS_POLL_SECONDS)
      end
    end

    def start_invariant_thread
      return unless @mode == :continuous
      return if @invariants.policy == :off
      return unless @invariants.sampler

      Thread.new do
        begin
          loop do
            break if @runtime.stop_flag.call

            begin
              Thread.handle_interrupt(InvariantSamplerShutdown => :immediate) do
                mark_invariant_thread_sleeping(true)
                @runtime.sleeper.call(@invariants.interval_seconds)
              end
            rescue StopIteration, InvariantSamplerShutdown
              break
            ensure
              mark_invariant_thread_sleeping(false)
            end

            break if @runtime.stop_flag.call

            Thread.handle_interrupt(InvariantSamplerShutdown => :never) do
              sample_invariants
            end
          end
        rescue StopIteration, InvariantSamplerShutdown
          nil
        rescue StandardError => error
          record_invariant_failure(error)
          trigger_stop(:invariant_sampler_failed)
        end
      end
    end

    # sample -> breach? -> enforce -> ++counter -> >=3? -> trigger_stop
    #                 -> warn    -> @stderr.puts (no counter)
    #                 -> off     -> unreachable (thread never started)
    #      -> !breach  -> counter = 0 (enforce only; harmless elsewhere)
    def sample_invariants
      sample = @invariants.sampler.call
      @run_state.append_invariant_sample(
        sampled_at: current_time,
        breach: sample.breach?,
        breaches: sample.breaches,
        checks: sample.checks.map(&:to_record),
      )
      return reset_invariant_breaches unless sample.breach?

      @run_state.append_warning(sample.to_warning)
      emit_invariant_warning(sample) if @invariants.policy == :warn
      return if @invariants.policy == :warn

      @invariants.consecutive_breaches += 1
      trigger_stop(:invariant_breach) if @invariants.consecutive_breaches >= 3
    end

    def reset_invariant_breaches
      @invariants.consecutive_breaches = 0 if @invariants.policy == :enforce
    end

    def emit_invariant_warning(sample)
      @stderr.puts("warning: invariant breach: #{sample.breaches.join('; ')}")
    end

    def trigger_stop(reason)
      return unless @runtime.stop_flag.respond_to?(:trigger)

      @runtime.stop_flag.trigger(reason)
    end

    def drain_workers(threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_DRAIN_TIMEOUT_SECONDS

      threads.each do |thread|
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        thread.join(remaining)
        next unless thread.alive?

        thread.kill
        thread.join
      end
    end

    def finish_run
      request_totals = aggregate_request_totals
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

    def stop_invariant_thread(thread)
      return unless thread
      return if thread == Thread.current

      if invariant_thread_sleeping?
        begin
          thread.raise(InvariantSamplerShutdown.new)
        rescue ThreadError
          nil
        end
      end
      thread.join
    end

    def tracking_buffer
      TrackingBuffer.new(self)
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

    def mark_invariant_thread_sleeping(value)
      @invariant_mutex.synchronize do
        @invariants.thread_sleeping = value
      end
    end

    def invariant_thread_sleeping?
      @invariant_mutex.synchronize do
        @invariants.thread_sleeping
      end
    end

    def record_invariant_failure(error)
      @invariant_mutex.synchronize do
        @invariants.failure ||= error
      end
    end

    def raise_invariant_failure_if_present
      failure = @invariant_mutex.synchronize do
        error = @invariants.failure
        @invariants.failure = nil
        error
      end
      return unless failure

      raise InvariantSamplerFailure, "invariant sampler failed"
    end

    def stop_adapter_safely(result)
      pid = @run_state.snapshot.dig(:adapter, :pid)
      return result unless pid

      @adapter_client.stop(pid:)
      result
    rescue AdapterClient::AdapterError
      if result.nil? || result == Load::ExitCodes::SUCCESS
        @run_state.merge(outcome: @run_state.outcome_payload(request_totals: aggregate_request_totals, aborted: true, error_code: "adapter_error"))
        return Load::ExitCodes::ADAPTER_ERROR
      end

      result
    end

    def register_tracking_buffer(buffer)
      @tracking_buffers << buffer
    end

    def aggregate_request_totals
      @tracking_buffers.each_with_object({ total: 0, ok: 0, error: 0 }) do |buffer, totals|
        buffer.request_totals.each do |key, value|
          totals[key] += value
        end
      end
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
