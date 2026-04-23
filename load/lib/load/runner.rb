# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "thread"
require "time"

module Load
  class Runner
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0
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
      end

      def record_ok(**kwargs)
        super(**kwargs)
        @runner.record_request_ok
        return if @started

        @started = true
        @runner.pin_window_start
      end

      def record_error(**kwargs)
        super(**kwargs)
        @runner.record_request_error
      end
    end

    def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:, http: Net::HTTP, readiness_path: "/up", startup_grace_seconds: 15, metrics_interval_seconds: 5, workload_file: nil, app_root: nil, adapter_bin: nil, stop_flag: nil)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @clock = clock
      @sleeper = sleeper
      @http = http
      @readiness_path = readiness_path
      @startup_grace_seconds = startup_grace_seconds
      @metrics_interval_seconds = metrics_interval_seconds
      @workload_file = workload_file
      @app_root = app_root
      @adapter_bin = adapter_bin
      @stop_flag = stop_flag || InternalStopFlag.new
      @state_mutex = Mutex.new
      @request_totals = { total: 0, ok: 0, error: 0 }
      @state = initial_state
      @window_started = false
    end

    def run

      begin
        @run_record.write_run(snapshot_state)
        adapter_describe = @adapter_client.describe
        validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
        write_state(adapter: {
          describe: adapter_describe,
          bin: @adapter_bin || @adapter_client.adapter_bin,
          app_root: @app_root,
        })

        @adapter_client.prepare(app_root: @app_root)
        reset_state = @adapter_client.reset_state(app_root: @app_root, workload: @workload.name, scale: @workload.scale)
        write_state(query_ids: Array(reset_state["query_ids"]).map(&:to_s)) if reset_state.is_a?(Hash) && reset_state["query_ids"]

        start_response = @adapter_client.start(app_root: @app_root)
        validate_adapter_response!(start_response, %w[pid base_url], "start")
        write_state(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

        probe_readiness(start_response.fetch("base_url"))
        start_workers(start_response.fetch("base_url"))

        result = finish_run
      rescue AdapterClient::AdapterError
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        result = 1
      rescue Load::ReadinessGate::Timeout
        write_state(outcome: outcome_payload(aborted: true, error_code: "readiness_timeout"))
        result = 1
      ensure
        result = stop_adapter_safely(result)
      end

      result
    end

    private

    def probe_readiness(base_url)
      write_state(
        window: {
          readiness: Load::ReadinessGate.new(
            base_url:,
            readiness_path: @readiness_path,
            startup_grace_seconds: @startup_grace_seconds,
            clock: @clock,
            sleeper: @sleeper,
            http: @http,
          ).call,
        },
      )
    end

    def start_workers(base_url)
      plan = @workload.load_plan
      client = Load::Client.new(base_url: base_url, http: @http)
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @clock, sleeper: @sleeper)
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed

      workers = Array.new(plan.workers) do |index|
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries: entries, rng: Random.new(seed + index)),
          buffer: tracking_buffer,
          client: client,
          ctx: { base_url: base_url },
          rng: Random.new(seed + index),
          rate_limiter: rate_limiter,
          stop_flag: @stop_flag,
        )
      end

      reporter = Load::Reporter.new(
        workers:,
        interval_seconds: @metrics_interval_seconds,
        sink: MetricsSink.new(@run_record),
        clock: @clock,
        sleeper: @sleeper,
      )
      reporter.start
      threads = workers.map { |worker| Thread.new { worker.run } }
      wait_for_window_end(plan.duration_seconds)
      drain_workers(threads)
      reporter.stop
    end

    def wait_for_window_end(duration_seconds)
      deadline = current_time + duration_seconds

      until @stop_flag.call
        remaining = deadline - current_time
        if remaining <= 0
          @stop_flag.trigger(:timeout) if @stop_flag.respond_to?(:trigger)
          break
        end

        Thread.pass
        next if @stop_flag.call

        remaining = deadline - current_time
        next if remaining <= 0

        @sleeper.call([1.0, remaining].min)
      end
    end

    def drain_workers(threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_DRAIN_TIMEOUT_SECONDS

      threads.each do |thread|
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        thread.join(remaining)
        next unless thread.alive?

        thread.raise(DrainTimeout)
        thread.join(0.1)
        thread.kill if thread.alive?
      end
    end

    def finish_run
      write_state(window: { end_ts: current_time })
      if @window_started
        write_state(outcome: outcome_payload(aborted: stop_aborted?))
        return 0
      end

      write_state(outcome: outcome_payload(aborted: true, error_code: "no_successful_requests"))
      3
    end

    def stop_aborted?
      return false unless @stop_flag.respond_to?(:reason)

      %i[sigint sigterm].include?(@stop_flag.reason)
    end

    def tracking_buffer
      TrackingBuffer.new(self)
    end

    def pin_window_start
      snapshot = nil
      @state_mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: current_time })
        snapshot = snapshot_state
      end
      @run_record.write_run(snapshot)
    end

    def current_time
      @clock.call
    end

    public :pin_window_start

    def initial_state
      {
        run_id: File.basename(@run_record.run_dir),
        workload: {
          name: @workload.name,
          file: workload_file,
          scale: @workload.scale.to_h,
          load_plan: @workload.load_plan.to_h,
          actions: @workload.actions.map { |entry| { class: entry.action_class.name, weight: entry.weight } },
        },
        adapter: {
          describe: nil,
          bin: @adapter_bin || @adapter_client.adapter_bin,
          app_root: @app_root,
          base_url: nil,
          pid: nil,
        },
        window: {
          start_ts: nil,
          end_ts: nil,
          readiness: {
            path: @readiness_path,
            probe_duration_ms: nil,
            probe_attempts: nil,
          },
          startup_grace_seconds: @startup_grace_seconds,
          metrics_interval_seconds: @metrics_interval_seconds,
        },
        outcome: outcome_payload(aborted: false),
        query_ids: [],
      }
    end

    def workload_file
      return @workload_file if @workload_file

      path = @workload.class.instance_method(:name).source_location&.first
      return nil unless path

      expanded = File.expand_path(path)
      cwd = "#{Dir.pwd}/"
      expanded.start_with?(cwd) ? expanded.delete_prefix(cwd) : expanded
    end

    def outcome_payload(aborted:, error_code: nil)
      {
        requests_total: @request_totals.fetch(:total),
        requests_ok: @request_totals.fetch(:ok),
        requests_error: @request_totals.fetch(:error),
        aborted:,
        error_code:,
      }.compact
    end

    def snapshot_state
      deep_copy(@state)
    end

    def record_request_ok
      @state_mutex.synchronize do
        @request_totals[:total] += 1
        @request_totals[:ok] += 1
      end
    end

    def record_request_error
      @state_mutex.synchronize do
        @request_totals[:total] += 1
        @request_totals[:error] += 1
      end
    end

    public :record_request_ok, :record_request_error

    def stop_adapter_safely(result)
      pid = @state.dig(:adapter, :pid)
      return result unless pid

      @adapter_client.stop(pid:)
      result
    rescue AdapterClient::AdapterError
      if result.nil? || result.zero?
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        return 1
      end

      result
    end

    def write_state(fragment)
      snapshot = nil
      @state_mutex.synchronize do
        @state = deep_merge(@state, fragment)
        snapshot = snapshot_state
      end
      @run_record.write_run(snapshot)
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
        @reason = reason
      end

      def call
        !@reason.nil?
      end
    end

    class ReadinessTimeout < StandardError
    end

    class DrainTimeout < StandardError
    end
  end
end
