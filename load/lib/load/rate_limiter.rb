# ABOUTME: Spaces requests according to a shared rate limit.
# ABOUTME: Preserves the limiter timing behavior used by the fixture harness.
require "thread"

module Load
  class RateLimiter
    def initialize(rate_limit:, clock:, sleeper:)
      @rate_limit = rate_limit
      @clock = clock
      @sleeper = sleeper
      @next_allowed_at = nil
      @mutex = Mutex.new
    end

    def wait_turn
      @mutex.synchronize do
        return if @rate_limit == :unlimited

        now = @clock.call
        @next_allowed_at ||= now
        sleep_for = @next_allowed_at - now
        @sleeper.call(sleep_for) if sleep_for.positive?
        @next_allowed_at = [@next_allowed_at, now].max + (1.0 / @rate_limit)
      end
    end
  end
end
