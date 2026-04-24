# ABOUTME: Spaces requests according to a shared rate limit.
# ABOUTME: Coordinates shared slot reservations without serializing worker sleeps.
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
      return if @rate_limit == :unlimited

      target_time = @mutex.synchronize do
        now = @clock.call
        @next_allowed_at ||= now
        target_time = [@next_allowed_at, now].max
        @next_allowed_at = target_time + (1.0 / @rate_limit)
        target_time
      end

      sleep_for = target_time - @clock.call
      @sleeper.call(sleep_for) if sleep_for.positive?
    end
  end
end
