# ABOUTME: Verifies the load rate limiter spaces requests correctly.
# ABOUTME: Covers unlimited and finite rate handling through injected clocks.
require_relative "test_helper"

class RateLimiterTest < Minitest::Test
  def test_unlimited_rate_never_sleeps
    limiter = Load::RateLimiter.new(rate_limit: :unlimited, clock: -> { 10.0 }, sleeper: ->(*) { flunk("unexpected sleep") })

    limiter.wait_turn
  end

  def test_finite_rate_spaces_requests
    sleeps = []
    times = [0.0, 0.0, 0.2].each
    limiter = Load::RateLimiter.new(rate_limit: 5.0, clock: -> { times.next }, sleeper: ->(seconds) { sleeps << seconds })

    limiter.wait_turn
    limiter.wait_turn

    assert_in_delta 0.2, sleeps.first, 0.001
  end
end
