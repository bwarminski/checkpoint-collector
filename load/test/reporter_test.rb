# ABOUTME: Verifies the reporter merges worker buffers into interval snapshots.
# ABOUTME: Covers the final tail flush behavior when the reporter stops.
require "timeout"
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
    assert_equal 5000, line.fetch(:interval_ms)
    assert line.key?(:ts)
    assert_equal 2, line.fetch(:actions).fetch(:a).fetch(:count)
  end

  def test_reporter_runs_periodic_snapshots_automatically
    workers = [FakeWorker.new(Load::Metrics::Buffer.new)]
    workers.first.buffer.record_ok(action: :a, latency_ns: 2_000_000, status: 200)
    sink = []
    sleep_calls = []
    ready = Queue.new
    release = Queue.new
    sleeper = ->(seconds) do
      sleep_calls << seconds
      if sleep_calls.length == 1
        ready << true
        release.pop
      else
        raise StopIteration
      end
    end
    reporter = Load::Reporter.new(workers:, interval_seconds: 5, sink:, clock: FakeClock.new([0.0]), sleeper:)

    reporter.start
    wait_until { !ready.empty? }
    assert_equal [], sink
    release << true
    wait_until { sink.any? }

    assert_equal 5, sleep_calls.first
    assert_equal 1, sink.length
    assert_equal 1, sink.last.fetch(:actions).fetch(:a).fetch(:count)
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

  def test_reporter_flushes_tail_data_even_if_never_started
    workers = [FakeWorker.new(Load::Metrics::Buffer.new)]
    workers.first.buffer.record_ok(action: :a, latency_ns: 2_000_000, status: 200)
    sink = []
    reporter = Load::Reporter.new(workers:, interval_seconds: 5, sink:, clock: FakeClock.new, sleeper: ->(*) {})

    reporter.stop

    assert_equal 1, sink.sum { |line| line.fetch(:actions).fetch(:a, {}).fetch(:count, 0) }
  end

  def test_reporter_stop_interrupts_waiting_sleeper_promptly
    workers = [FakeWorker.new(Load::Metrics::Buffer.new)]
    sink = []
    started = Queue.new
    blocker = Queue.new
    reporter = Load::Reporter.new(
      workers:,
      interval_seconds: 5,
      sink:,
      clock: FakeClock.new([0.0]),
      sleeper: ->(*) do
        started << true
        blocker.pop
      end,
    )

    reporter.start
    started.pop

    elapsed = Timeout.timeout(0.5) do
      start_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      reporter.stop
      (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start_ns) / 1_000_000_000.0
    end

    assert_operator elapsed, :<, 0.2
    assert_equal 1, sink.length
  end

  private

  def wait_until(timeout_seconds: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

    until yield
      raise "timed out waiting for reporter" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
