# ABOUTME: Waits for startup readiness or a fixed grace period before the run window opens.
# ABOUTME: Encapsulates retry timing and readiness payload generation for the runner.
module Load
  class ReadinessGate
    class Timeout < StandardError
      def initialize
        super("readiness_timeout")
      end
    end

    def initialize(base_url:, readiness_path:, startup_grace_seconds:, clock:, sleeper:, http:)
      @base_url = base_url
      @readiness_path = readiness_path
      @startup_grace_seconds = startup_grace_seconds
      @clock = clock
      @sleeper = sleeper
      @http = http
    end

    def call
      return sleep_startup_grace if @readiness_path.nil?

      client = Load::Client.new(base_url: @base_url, http: @http)
      probe_started_at = current_time
      deadline = current_time + @startup_grace_seconds
      backoff = 0.2
      attempts = 0

      loop do
        raise Timeout if current_time >= deadline

        attempts += 1
        response = client.get(@readiness_path)
        raise Timeout if current_time >= deadline

        return readiness_payload(probe_started_at:, attempts:) if success?(response)

        sleep_until_retry(deadline, backoff)
        backoff = next_backoff(backoff)
      rescue StandardError
        raise Timeout if current_time >= deadline

        sleep_until_retry(deadline, backoff)
        backoff = next_backoff(backoff)
      end
    end

    private

    def success?(response)
      code = response.code.to_i
      code >= 200 && code < 300
    end

    def sleep_startup_grace
      @sleeper.call(@startup_grace_seconds)
      readiness_payload(
        probe_started_at: current_time,
        attempts: 0,
        duration_ms: (@startup_grace_seconds * 1000).round,
        path: "none",
      )
    end

    def sleep_until_retry(deadline, backoff)
      @sleeper.call([backoff, deadline - current_time].min)
    end

    def next_backoff(backoff)
      [backoff * 2, 1.6].min
    end

    def readiness_payload(probe_started_at:, attempts:, duration_ms: nil, path: @readiness_path)
      {
        completed_at: current_time,
        path: path || "none",
        probe_duration_ms: duration_ms || ((current_time - probe_started_at) * 1000).round,
        probe_attempts: attempts,
      }
    end

    def current_time
      @clock.call
    end
  end
end
