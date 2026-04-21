# ABOUTME: Verifies in-memory metrics capture latencies, errors, and percentiles.
# ABOUTME: Covers the per-worker buffer snapshot contract used by the reporter.
require_relative "test_helper"

class MetricsTest < Minitest::Test
  def test_snapshot_computes_percentiles_and_errors
    buffer = Load::Metrics::Buffer.new
    buffer.record_ok(action: :list_open_todos, latency_ns: 10_000_000, status: 200)
    buffer.record_ok(action: :list_open_todos, latency_ns: 30_000_000, status: 200)
    buffer.record_error(action: :list_open_todos, latency_ns: 50_000_000, error_class: "Net::ReadTimeout")

    snapshot = buffer.swap!

    stats = Load::Metrics::Snapshot.build(snapshot).fetch(:list_open_todos)
    assert_equal 3, stats.fetch(:count)
    assert_equal 1, stats.fetch(:error_count)
    assert_in_delta 30.0, stats.fetch(:p50_ms), 0.1
    assert_in_delta 30.0, stats.fetch(:p95_ms), 0.1
    assert_in_delta 50.0, stats.fetch(:p99_ms), 0.1
    assert_in_delta 50.0, stats.fetch(:max_ms), 0.1
  end
end
