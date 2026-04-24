# ABOUTME: Verifies startup readiness probing and disabled-probe behavior.
# ABOUTME: Covers timeout handling, backoff clamping, and readiness payloads.
require_relative "test_helper"

class ReadinessGateTest < Minitest::Test
  def test_call_returns_none_payload_when_readiness_path_is_nil
    clock = FakeClock.new(Time.utc(2026, 4, 23, 0, 0, 0))
    gate = Load::ReadinessGate.new(
      base_url: "http://127.0.0.1:3999",
      readiness_path: nil,
      startup_grace_seconds: 0.05,
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds) },
      http: FakeHttp.new,
    )

    payload = gate.call

    assert_equal "none", payload.fetch(:path)
    assert_equal 0, payload.fetch(:probe_attempts)
    assert_equal 50, payload.fetch(:probe_duration_ms)
  end

  def test_call_raises_timeout_after_startup_grace_budget
    clock = FakeClock.new(Time.utc(2026, 4, 23, 0, 0, 0))
    http = ProbeHttp.new
    gate = Load::ReadinessGate.new(
      base_url: "http://127.0.0.1:3999",
      readiness_path: "/up",
      startup_grace_seconds: 0.01,
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds) },
      http:,
    )

    error = assert_raises(Load::ReadinessGate::Timeout) { gate.call }

    assert_equal 1, http.request_count
    assert_equal "readiness_timeout", error.message
  end

  class FakeClock
    attr_reader :now

    def initialize(now)
      @now = now
    end

    def advance_by(seconds)
      @now += seconds
    end
  end

  class FakeHttp
    Response = Struct.new(:code)

    def start(*)
      yield self
    end

    def request(*)
      Response.new("200")
    end
  end

  class ProbeHttp
    Response = Struct.new(:code)

    attr_reader :request_count

    def initialize
      @request_count = 0
    end

    def start(*)
      @request_count += 1
      yield self
    end

    def request(*)
      Response.new("500")
    end
  end
end
