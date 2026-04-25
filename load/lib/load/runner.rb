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
        @runner.pin_window_start
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

    InvariantSample = Data.define(:open_count, :total_count, :open_floor, :total_floor, :total_ceiling) do
      def breaches
        [].tap do |messages|
          messages << "open_count #{open_count} is below open_floor #{open_floor}" if open_count < open_floor
          messages << "total_count #{total_count} is below total_floor #{total_floor}" if total_count < total_floor
          messages << "total_count #{total_count} is above total_ceiling #{total_ceiling}" if total_count > total_ceiling
        end
      end

      def breach?
        !breaches.empty?
      end

      def healthy?
        !breach?
      end

      def to_warning
        {
          type: "invariant_breach",
          message: breaches.join("; "),
          open_count:,
          total_count:,
          open_floor:,
          total_floor:,
          total_ceiling:,
        }
      end

      def to_record(sampled_at:)
        {
          sampled_at:,
          open_count:,
          total_count:,
          open_floor:,
          total_floor:,
          total_ceiling:,
          breach: breach?,
          breaches:,
        }
      end
    end

    class InvariantSampler
      OPEN_COUNT_SQL = "SELECT COUNT(*) AS count FROM todos WHERE status = 'open'".freeze
      TOTAL_COUNT_SQL = "SELECT reltuples::bigint AS count FROM pg_class WHERE relname = 'todos'".freeze

      def initialize(pg:, database_url:, open_floor:, total_floor:, total_ceiling:)
        @pg = pg
        @database_url = database_url
        @open_floor = open_floor
        @total_floor = total_floor
        @total_ceiling = total_ceiling
      end

      def call
        with_connection do |connection|
          connection.transaction do |txn|
            txn.exec("SET LOCAL pg_stat_statements.track = 'none'")
            open_count = txn.exec(OPEN_COUNT_SQL).first.fetch("count").to_i
            total_count = txn.exec(TOTAL_COUNT_SQL).first.fetch("count").to_i
            InvariantSample.new(
              open_count:,
              total_count:,
              open_floor: @open_floor,
              total_floor: @total_floor,
              total_ceiling: @total_ceiling,
            )
          end
        end
      end

      private

      def with_connection
        connection = @pg.connect(@database_url)
        yield connection
      ensure
        connection&.close
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
      @invariant_policy = invariant_policy
      @invariant_sampler = invariant_sampler || default_invariant_sampler(database_url:, pg:)
      @invariant_sample_interval_seconds = invariant_sample_interval_seconds
      @state_mutex = Mutex.new
      @tracking_buffers = []
      @state = initial_state
      @window_started = false
      @consecutive_invariant_breaches = 0
      @invariant_thread_sleeping = false
      @invariant_failure = nil
    end

    def run
      begin
        @run_record.write_run(snapshot_state)
        adapter_describe = @adapter_client.describe
        validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
        write_state(adapter: {
          describe: adapter_describe,
          bin: @settings.adapter_bin || @adapter_client.adapter_bin,
          app_root: @settings.app_root,
        })

        @adapter_client.prepare(app_root: @settings.app_root)
        reset_state = @adapter_client.reset_state(app_root: @settings.app_root, workload: @workload.name, scale: @workload.scale)
        write_state(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if reset_state.is_a?(Hash) && reset_state["query_ids"]

        start_response = @adapter_client.start(app_root: @settings.app_root)
        validate_adapter_response!(start_response, %w[pid base_url], "start")
        write_state(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

        probe_readiness(start_response.fetch("base_url"))
        verify_fixture(base_url: start_response.fetch("base_url"))
        start_workers(start_response.fetch("base_url"))

        result = finish_run
      rescue InvariantSamplerFailure
        write_state(outcome: outcome_payload(aborted: true, error_code: "invariant_sampler_failed"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::FixtureVerifier::VerificationError => error
        write_state(outcome: outcome_payload(aborted: true, error_code: "fixture_verification_failed").merge(error_message: error.message))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue AdapterClient::AdapterError
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        result = Load::ExitCodes::ADAPTER_ERROR
      rescue Load::ReadinessGate::Timeout
        write_state(outcome: outcome_payload(aborted: true, error_code: "readiness_timeout"))
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
      write_state(
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
      threads = []
      invariant_thread = nil

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
      return if @invariant_policy == :off
      return unless @invariant_sampler

      Thread.new do
        begin
          loop do
            break if @runtime.stop_flag.call

            begin
              Thread.handle_interrupt(InvariantSamplerShutdown => :immediate) do
                mark_invariant_thread_sleeping(true)
                @runtime.sleeper.call(@invariant_sample_interval_seconds)
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
      sample = @invariant_sampler.call
      append_invariant_sample(sample)
      return reset_invariant_breaches unless sample.breach?

      append_warning(sample.to_warning)
      emit_invariant_warning(sample) if @invariant_policy == :warn
      return if @invariant_policy == :warn

      @consecutive_invariant_breaches += 1
      trigger_stop(:invariant_breach) if @consecutive_invariant_breaches >= 3
    end

    def reset_invariant_breaches
      @consecutive_invariant_breaches = 0 if @invariant_policy == :enforce
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
      write_state(window: { end_ts: current_time })
      if stop_reason == :invariant_breach || @window_started
        write_state(outcome: final_outcome)
        return final_exit_code
      end

      write_state(outcome: outcome_payload(aborted: true, error_code: "no_successful_requests"))
      Load::ExitCodes::NO_SUCCESSFUL_REQUESTS
    end

    def final_outcome
      if stop_reason == :invariant_breach
        outcome_payload(aborted: true, error_code: "invariant_breach")
      else
        outcome_payload(aborted: stop_aborted?)
      end
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

    def pin_window_start
      @state_mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: current_time })
        @run_record.write_run(snapshot_state)
      end
    end

    def current_time
      @runtime.clock.call
    end

    public :pin_window_start

    def initial_state
      {
        run_id: File.basename(@run_record.run_dir),
        schema_version: 1,
        workload: {
          name: @workload.name,
          file: workload_file,
          scale: @workload.scale.to_h,
          load_plan: @workload.load_plan.to_h,
          actions: @workload.actions.map { |entry| { class: entry.action_class.name, weight: entry.weight } },
        },
        adapter: {
          describe: nil,
          bin: @settings.adapter_bin || @adapter_client.adapter_bin,
          app_root: @settings.app_root,
          base_url: nil,
          pid: nil,
        },
        window: {
          start_ts: nil,
          end_ts: nil,
          readiness: {
            path: @settings.readiness_path,
            probe_duration_ms: nil,
            probe_attempts: nil,
          },
          startup_grace_seconds: @settings.startup_grace_seconds,
          metrics_interval_seconds: @settings.metrics_interval_seconds,
        },
        outcome: outcome_payload(aborted: false),
        query_ids: [],
        warnings: [],
        invariant_samples: [],
      }
    end

    def workload_file
      return @settings.workload_file if @settings.workload_file

      path = @workload.class.instance_method(:name).source_location&.first
      return nil unless path

      expanded = File.expand_path(path)
      cwd = "#{Dir.pwd}/"
      expanded.start_with?(cwd) ? expanded.delete_prefix(cwd) : expanded
    end

    def outcome_payload(aborted:, error_code: nil)
      request_totals = aggregate_request_totals
      {
        requests_total: request_totals.fetch(:total),
        requests_ok: request_totals.fetch(:ok),
        requests_error: request_totals.fetch(:error),
        aborted:,
        error_code:,
      }.compact
    end

    def snapshot_state
      deep_copy(@state)
    end

    def mark_invariant_thread_sleeping(value)
      @state_mutex.synchronize do
        @invariant_thread_sleeping = value
      end
    end

    def invariant_thread_sleeping?
      @state_mutex.synchronize do
        @invariant_thread_sleeping
      end
    end

    def record_invariant_failure(error)
      @state_mutex.synchronize do
        @invariant_failure ||= error
      end
    end

    def raise_invariant_failure_if_present
      failure = @state_mutex.synchronize do
        error = @invariant_failure
        @invariant_failure = nil
        error
      end
      return unless failure

      raise InvariantSamplerFailure, "invariant sampler failed"
    end

    def stop_adapter_safely(result)
      pid = @state.dig(:adapter, :pid)
      return result unless pid

      @adapter_client.stop(pid:)
      result
    rescue AdapterClient::AdapterError
      if result.nil? || result == Load::ExitCodes::SUCCESS
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        return Load::ExitCodes::ADAPTER_ERROR
      end

      result
    end

    def write_state(fragment)
      @state_mutex.synchronize do
        @state = deep_merge(@state, fragment)
        @run_record.write_run(snapshot_state)
      end
    end

    def append_warning(payload)
      @state_mutex.synchronize do
        warnings = @state.fetch(:warnings).dup
        warnings << deep_copy(payload)
        @state = deep_merge(@state, warnings:)
        @run_record.write_run(snapshot_state)
      end
    end

    def append_invariant_sample(sample)
      @state_mutex.synchronize do
        invariant_samples = @state.fetch(:invariant_samples).dup
        invariant_samples << deep_copy(sample.to_record(sampled_at: current_time))
        @state = deep_merge(@state, invariant_samples:)
        @run_record.write_run(snapshot_state)
      end
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

    def default_invariant_sampler(database_url:, pg:)
      return nil unless @mode == :continuous
      if database_url.nil? || database_url.empty?
        raise AdapterClient::AdapterError, "continuous mode requires DATABASE_URL or an explicit invariant sampler"
      end

      rows_per_table = @workload.scale.rows_per_table
      InvariantSampler.new(
        pg:,
        database_url:,
        open_floor: (rows_per_table * 0.3).to_i,
        total_floor: (rows_per_table * 0.8).to_i,
        total_ceiling: (rows_per_table * 2.0).to_i,
      )
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
