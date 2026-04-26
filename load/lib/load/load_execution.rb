# ABOUTME: Runs workload traffic through workers and reporters for one load window.
# ABOUTME: Owns worker construction, wait-loop behavior, request totals, and thread drain.
module Load
  class LoadExecution
    WORKER_DRAIN_TIMEOUT_SECONDS = 1.0
    CONTINUOUS_POLL_SECONDS = 0.1

    MetricsSink = Data.define(:run_record) do
      def <<(line)
        run_record.append_metrics(line)
      end
    end

    class TrackingBuffer < Load::Metrics::Buffer
      def initialize(on_first_success:)
        super()
        @on_first_success = on_first_success
        @started = false
        @request_totals = { total: 0, ok: 0, error: 0 }
      end

      def record_ok(**kwargs)
        super(**kwargs)
        @request_totals[:total] += 1
        @request_totals[:ok] += 1
        return if @started

        @started = true
        @on_first_success.call
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

    attr_reader :request_totals

    def initialize(workload:, base_url:, runtime:, metrics_interval_seconds:, run_record:, on_first_success:, reporter_factory: nil)
      @workload = workload
      @base_url = base_url
      @runtime = runtime
      @metrics_interval_seconds = metrics_interval_seconds
      @run_record = run_record
      @reporter_factory = reporter_factory
      @request_totals = { total: 0, ok: 0, error: 0 }
      @first_success = FirstSuccess.new(on_first_success)
    end

    def run(mode:, duration_seconds:)
      begin
        workers = build_workers
        reporter = build_reporter(workers)
        threads = workers.map { |worker| Thread.new { worker.run } }
        reporter.start
        wait(mode:, duration_seconds:)
      ensure
        drain_threads(threads) if threads
        request_totals = aggregate_request_totals(workers || [])
        reporter&.stop
      end

      request_totals
    end

    private

    class FirstSuccess
      def initialize(callback)
        @callback = callback
        @mutex = Mutex.new
        @seen = false
      end

      def call
        @mutex.synchronize do
          return if @seen

          @seen = true
        end

        @callback.call
      end
    end

    def build_workers
      plan = @workload.load_plan
      entries = @workload.actions
      seed = plan.seed.nil? ? @workload.scale.seed : plan.seed
      rate_limiter = Load::RateLimiter.new(rate_limit: plan.rate_limit, clock: @runtime.clock, sleeper: @runtime.sleeper)

      Array.new(plan.workers) do |index|
        Load::Worker.new(
          worker_id: index + 1,
          selector: Load::Selector.new(entries:, rng: Random.new(seed + index)),
          buffer: TrackingBuffer.new(on_first_success: @first_success),
          client: Load::Client.new(base_url: @base_url, http: @runtime.http),
          ctx: { base_url: @base_url, scale: @workload.scale },
          rng: Random.new(seed + index),
          rate_limiter:,
          stop_flag: @runtime.stop_flag,
        )
      end
    end

    def build_reporter(workers)
      return @reporter_factory.call(workers:) if @reporter_factory

      Load::Reporter.new(
        workers:,
        interval_seconds: @metrics_interval_seconds,
        sink: MetricsSink.new(@run_record),
        clock: @runtime.clock,
        sleeper: @runtime.sleeper,
      )
    end

    def wait(mode:, duration_seconds:)
      if mode == :continuous
        wait_for_stop_signal
      else
        wait_for_window_end(duration_seconds)
      end
    end

    def wait_for_window_end(duration_seconds)
      deadline = @runtime.clock.call + duration_seconds

      until @runtime.stop_flag.call
        remaining = deadline - @runtime.clock.call
        if remaining <= 0
          @runtime.stop_flag.trigger(:timeout) if @runtime.stop_flag.respond_to?(:trigger)
          break
        end

        Thread.pass
        next if @runtime.stop_flag.call

        remaining = deadline - @runtime.clock.call
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

    def drain_threads(threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_DRAIN_TIMEOUT_SECONDS

      threads.each do |thread|
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        thread.join(remaining)
        next unless thread.alive?

        thread.kill
        thread.join
      end
    end

    def aggregate_request_totals(workers)
      @request_totals = workers.each_with_object({ total: 0, ok: 0, error: 0 }) do |worker, totals|
        worker.buffer.request_totals.each do |key, value|
          totals[key] += value
        end
      end
    end
  end
end
