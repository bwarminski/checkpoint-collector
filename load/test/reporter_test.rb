# ABOUTME: Verifies the reporter merges worker buffers into interval snapshots.
# ABOUTME: Covers the final tail flush behavior when the reporter stops.
require_relative "test_helper"

class ReporterTest < Minitest::Test
  FakeWorker = Struct.new(:buffer)

  class FakeClock
    def initialize(times = [0.0])
      @times = times.each
    end

    def call
      @times.next
    end
  end

  def test_reporter_merges_per_worker_buffers_at_each_interval
    workers = [FakeWorker.new(Load::Metrics::Buffer.new), FakeWorker.new(Load::Metrics::Buffer.new)]
    workers[0].buffer.record_ok(action: :a, latency_ns: 5_000_000, status: 200)
    workers[1].buffer.record_ok(action: :a, latency_ns: 15_000_000, status: 200)
    sink = []
    reporter = Load::Reporter.new(workers:, interval_seconds: 5, sink:, clock: FakeClock.new([0.0, 5.0]), sleeper: ->(*) {})

    reporter.snapshot_once

    line = sink.last
    assert_equal 2, line.fetch(:actions).fetch(:a).fetch(:count)
  end

  def test_reporter_emits_final_tail_snapshot_on_stop
    workers = [FakeWorker.new(Load::Metrics::Buffer.new)]
    sink = []
    reporter = Load::Reporter.new(workers:, interval_seconds: 5, sink:, clock: FakeClock.new, sleeper: ->(*) {})

    reporter.start
    workers.first.buffer.record_ok(action: :a, latency_ns: 2_000_000, status: 200)
    reporter.stop

    assert_equal 1, sink.sum { |line| line.fetch(:actions).fetch(:a, {}).fetch(:count, 0) }
  end
end
