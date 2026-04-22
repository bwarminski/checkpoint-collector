# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "thread"
require "time"

module Load
  class Runner
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0

    def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:, http: Net::HTTP, readiness_timeout_seconds: 15, readiness_path: "/up", startup_grace_seconds: 15, metrics_interval_seconds: 5, app_root: nil, adapter_bin: nil, stop_flag: nil)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @clock = clock
      @sleeper = sleeper
      @http = http
      @readiness_timeout_seconds = readiness_timeout_seconds
      @readiness_path = readiness_path
      @startup_grace_seconds = startup_grace_seconds
      @metrics_interval_seconds = metrics_interval_seconds
      @app_root = app_root
      @adapter_bin = adapter_bin
      @stop_flag = stop_flag || InternalStopFlag.new
      @state_mutex = Mutex.new
      @request_totals = { total: 0, ok: 0, error: 0 }
      @state = initial_state
      @window_started = false
    end

    def run
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

      finish_run
    rescue AdapterClient::AdapterError => error
      write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
      1
    rescue ReadinessTimeout
      write_state(outcome: outcome_payload(aborted: true, error_code: "readiness_timeout"))
      1
    ensure
      begin
        @adapter_client.stop(pid: @state.dig(:adapter, :pid)) if @state.dig(:adapter, :pid)
      rescue AdapterClient::AdapterError
        write_state(outcome: outcome_payload(aborted: true, error_code: "adapter_error"))
        return 1
      end
    end

    private

    def probe_readiness(base_url)
      return sleep_startup_grace if @readiness_path == "none"

      client = Load::Client.new(base_url: base_url, http: @http)
      probe_started_at = current_time
      deadline = current_time + @startup_grace_seconds
      backoff = 0.2
      attempts = 0

      loop do
        raise ReadinessTimeout if current_time >= deadline

        attempts += 1
        response = client.get(@readiness_path)
        raise ReadinessTimeout if current_time >= deadline

        if response.code.to_i >= 200 && response.code.to_i < 300
          write_state(window: { readiness: readiness_payload(probe_started_at:, attempts:) })
          return
        end

        raise ReadinessTimeout if current_time >= deadline

        sleep_for = [backoff, deadline - current_time].min
        @sleeper.call(sleep_for)
        backoff = [backoff * 2, 1.6].min
      rescue StandardError
        raise ReadinessTimeout if current_time >= deadline

        sleep_for = [backoff, deadline - current_time].min
        @sleeper.call(sleep_for)
        backoff = [backoff * 2, 1.6].min
      end
    end

    def sleep_startup_grace
      @sleeper.call(@startup_grace_seconds)
      started_at = current_time
      write_state(
        window: {
          readiness: readiness_payload(
            probe_started_at: started_at,
            attempts: 0,
            duration_ms: (@startup_grace_seconds * 1000).round,
            path: "none",
          ),
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
        buffer = tracking_buffer
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries: entries, rng: Random.new(seed + index)),
          buffer: buffer,
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
        sink: metrics_sink,
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
      callback = method(:pin_window_start)
      ok_callback = method(:record_request_ok)
      error_callback = method(:record_request_error)

      Class.new(Load::Metrics::Buffer) do
        define_method(:initialize) do |callback, ok_callback, error_callback|
          super()
          @callback = callback
          @ok_callback = ok_callback
          @error_callback = error_callback
          @started = false
        end

        define_method(:record_ok) do |**kwargs|
          super(**kwargs)
          @ok_callback.call
          return if @started

          @started = true
          @callback.call
        end

        define_method(:record_error) do |**kwargs|
          super(**kwargs)
          @error_callback.call
        end
      end.new(callback, ok_callback, error_callback)
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

    def metrics_sink
      run_record = @run_record
      Object.new.tap do |sink|
        sink.define_singleton_method(:<<) do |line|
          run_record.append_metrics(line)
        end
      end
    end

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
      path = @workload.class.instance_method(:name).source_location&.first
      return nil unless path

      expanded = File.expand_path(path)
      cwd = "#{Dir.pwd}/"
      expanded.start_with?(cwd) ? expanded.delete_prefix(cwd) : expanded
    end

    def readiness_payload(probe_started_at:, attempts:, duration_ms: nil, path: @readiness_path)
      {
        completed_at: current_time,
        path:,
        probe_duration_ms: duration_ms || ((current_time - probe_started_at) * 1000).round,
        probe_attempts: attempts,
      }
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
