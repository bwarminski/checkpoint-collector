# ABOUTME: Orchestrates adapter lifecycle, readiness probing, and worker execution.
# ABOUTME: Writes run state as workers report the first successful response.
require "net/http"
require "thread"
require "time"

module Load
  class Runner
    def initialize(workload:, adapter_client:, run_record:, clock:, sleeper:, http: Net::HTTP, readiness_timeout_seconds: 15, readiness_path: "/up", startup_grace_seconds: 15, app_root: nil, adapter_bin: nil, stop_flag: nil)
      @workload = workload
      @adapter_client = adapter_client
      @run_record = run_record
      @clock = clock
      @sleeper = sleeper
      @http = http
      @readiness_timeout_seconds = readiness_timeout_seconds
      @readiness_path = readiness_path
      @startup_grace_seconds = startup_grace_seconds
      @app_root = app_root
      @adapter_bin = adapter_bin
      @stop_flag = stop_flag || InternalStopFlag.new
      @state_mutex = Mutex.new
      @state = {
        workload: {
          name: workload.name,
          scale: workload.scale.to_h,
          load_plan: workload.load_plan.to_h,
        },
        outcome: {
          aborted: false,
        },
      }
      @window_started = false
    end

    def run
      adapter_describe = @adapter_client.describe
      validate_adapter_response!(adapter_describe, %w[name framework runtime], "describe")
      write_state(adapter: {
        describe: adapter_describe,
        bin: @adapter_bin || @adapter_client.adapter_bin,
        app_root: @app_root,
      })

      @adapter_client.prepare(app_root: @app_root)
      @adapter_client.reset_state(app_root: @app_root, scale: @workload.scale)

      start_response = @adapter_client.start(app_root: @app_root)
      validate_adapter_response!(start_response, %w[pid base_url], "start")
      write_state(adapter: { pid: start_response.fetch("pid"), base_url: start_response.fetch("base_url") })

      probe_readiness(start_response.fetch("base_url"))
      start_workers(start_response.fetch("base_url"))

      finish_run
    rescue AdapterClient::AdapterError => error
      write_state(outcome: @state.fetch(:outcome).merge(aborted: true, error_code: "adapter_error"))
      1
    rescue ReadinessTimeout
      write_state(outcome: @state.fetch(:outcome).merge(aborted: true, error_code: "readiness_timeout"))
      1
    ensure
      begin
        @adapter_client.stop(pid: @state.dig(:adapter, :pid)) if @state.dig(:adapter, :pid)
      rescue AdapterClient::AdapterError
        write_state(outcome: @state.fetch(:outcome).merge(aborted: true, error_code: "adapter_error"))
        return 1
      end
    end

    private

    def probe_readiness(base_url)
      return sleep_startup_grace if @readiness_path == "none"

      client = Load::Client.new(base_url: base_url, http: @http)
      deadline = current_time + @startup_grace_seconds
      backoff = 0.2

      loop do
        raise ReadinessTimeout if current_time >= deadline

        response = client.get(@readiness_path)
        raise ReadinessTimeout if current_time >= deadline

        if response.code.to_i >= 200 && response.code.to_i < 300
          write_state(window: { readiness: { completed_at: current_time, path: @readiness_path } })
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
      write_state(window: { readiness: { completed_at: current_time, path: "none" } })
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

      threads = workers.map { |worker| Thread.new { worker.run } }
      wait_for_window_end(plan.duration_seconds)
      threads.each(&:join)
    end

    def wait_for_window_end(duration_seconds)
      deadline = current_time + duration_seconds

      until @stop_flag.call
        if current_time >= deadline
          @stop_flag.trigger(:timeout) if @stop_flag.respond_to?(:trigger)
          break
        end

        @sleeper.call(0.01)
        Thread.pass
      end
    end

    def finish_run
      write_state(window: { end_ts: current_time })
      if @window_started
        write_state(outcome: @state.fetch(:outcome).merge(aborted: stop_aborted?))
        return 0
      end

      write_state(outcome: @state.fetch(:outcome).merge(aborted: true, error_code: "no_successful_requests"))
      3
    end

    def stop_aborted?
      return false unless @stop_flag.respond_to?(:reason)

      %i[sigint sigterm].include?(@stop_flag.reason)

    end

    def tracking_buffer
      callback = method(:pin_window_start)

      Class.new(Load::Metrics::Buffer) do
        define_method(:initialize) do |callback|
          super()
          @callback = callback
          @started = false
        end

        define_method(:record_ok) do |**kwargs|
          super(**kwargs)
          return if @started

          @started = true
          @callback.call
        end
      end.new(callback)
    end

    def pin_window_start
      snapshot = nil
      @state_mutex.synchronize do
        return if @window_started

        @window_started = true
        @state = deep_merge(@state, window: { start_ts: current_time })
        snapshot = @state
      end
      @run_record.write_run(snapshot)
    end

    def current_time
      @clock.call
    end

    def write_state(fragment)
      snapshot = nil
      @state_mutex.synchronize do
        @state = deep_merge(@state, fragment)
        snapshot = @state
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
  end
end
