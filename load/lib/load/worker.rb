# ABOUTME: Runs selected actions, records outcomes, and keeps the worker loop moving.
# ABOUTME: Captures selector and action failures in the worker's own metrics buffer.
module Load
  class Worker
    def initialize(worker_id:, selector:, buffer:, client:, ctx:, rng:, rate_limiter:, stop_flag:)
      @worker_id = worker_id
      @selector = selector
      @buffer = buffer
      @client = client
      @ctx = ctx
      @rng = rng
      @rate_limiter = rate_limiter
      @stop_flag = stop_flag
    end

    attr_reader :buffer

    def run
      @client.start if @client.respond_to?(:start)

      until @stop_flag.call
        action = nil
        request_started_ns = nil

        begin
          @rate_limiter.wait_turn
          entry = @selector.next
          action = entry.action_class.new(rng: @rng, ctx: @ctx, client: @client)
          request_started_ns = monotonic_ns
          response = action.call
          @buffer.record_ok(action: action.name, latency_ns: elapsed_ns(request_started_ns), status: response.code.to_i)
        rescue StandardError => error
          @buffer.record_error(action: action_name(action), latency_ns: request_started_ns ? elapsed_ns(request_started_ns) : 0, error_class: error.class.name)
        end
      end
    ensure
      @client.finish if @client.respond_to?(:finish)
    end

    private

    def action_name(action)
      return :unknown unless action && action.respond_to?(:name)

      action.name
    rescue StandardError
      :unknown
    end

    def elapsed_ns(started_ns)
      monotonic_ns - started_ns
    end

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end
end
