# ABOUTME: Verifies the missing-index fixture assertion checks the plan and ClickHouse signal.
# ABOUTME: Covers the last-run file path fix, timeout handling, and missing-file errors before implementation exists.
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require_relative "../../../fixtures/missing-index/validate/assert"
require_relative "../../lib/fixtures/manifest"

class MissingIndexAssertTest < Minitest::Test
  def test_passes_when_explain_root_is_seq_scan_and_clickhouse_threshold_is_met
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [
      {
        "QUERY PLAN" => JSON.generate(
          [
            {
              "Plan" => {
                "Node Type" => "Seq Scan",
                "Relation Name" => "todos",
              },
            },
          ]
        ),
      },
    ]
    snapshots = [
      { "calls" => "250", "mean_ms" => "41.0" },
      { "calls" => "600", "mean_ms" => "42.3" },
    ]
    stdout = StringIO.new

    Fixtures::MissingIndex::Assert.new(
      manifest: manifest,
      options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 20, last_run_path: fixture_last_run_path },
      stdout: stdout,
      pg: FakePg.new(explain_rows),
      clickhouse_query: ->(*) { snapshots.shift },
      sleeper: ->(*) {},
    ).run

    assert_includes stdout.string, "FIXTURE: missing-index"
    assert_includes stdout.string, "PASS: explain (Seq Scan on todos, plan node confirmed)"
    assert_includes stdout.string, "PASS: clickhouse (600 calls; mean 42.3ms)"
  end

  def test_fails_when_plan_flips_to_index_scan
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [
      {
        "QUERY PLAN" => JSON.generate(
          [
            {
              "Plan" => {
                "Node Type" => "Index Scan",
                "Relation Name" => "todos",
              },
            },
          ]
        ),
      },
    ]

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Assert.new(
        manifest: manifest,
        options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 1, last_run_path: fixture_last_run_path },
        stdout: StringIO.new,
        pg: FakePg.new(explain_rows),
        clickhouse_query: ->(*) { { "calls" => "600", "mean_ms" => "2.3" } },
        sleeper: ->(*) {},
      ).run
    end

    assert_includes error.message, "Expected Seq Scan"
  end

  def test_clickhouse_timeout_raises_with_call_count
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [
      {
        "QUERY PLAN" => JSON.generate(
          [
            {
              "Plan" => {
                "Node Type" => "Seq Scan",
                "Relation Name" => "todos",
              },
            },
          ]
        ),
      },
    ]

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Assert.new(
        manifest: manifest,
        options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 0, last_run_path: fixture_last_run_path },
        stdout: StringIO.new,
        pg: FakePg.new(explain_rows),
        clickhouse_query: ->(*) { { "calls" => "10", "mean_ms" => "0.0" } },
        sleeper: ->(*) {},
      ).run
    end

    assert_includes error.message, "10"
  end

  def test_missing_last_run_file_raises_clear_error
    manifest = Fixtures::Manifest.load("missing-index")
    explain_rows = [
      {
        "QUERY PLAN" => JSON.generate(
          [
            {
              "Plan" => {
                "Node Type" => "Seq Scan",
                "Relation Name" => "todos",
              },
            },
          ]
        ),
      },
    ]

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Assert.new(
        manifest: manifest,
        options: { clickhouse_url: "http://clickhouse:8123", timeout_seconds: 1, last_run_path: "/nonexistent/fixture-last-run.json" },
        stdout: StringIO.new,
        pg: FakePg.new(explain_rows),
        clickhouse_query: ->(*) { {} },
        sleeper: ->(*) {},
      ).run
    end

    assert_includes error.message, "fixture-last-run.json"
  end

  private

  def fixture_last_run_path
    path = File.expand_path("../../../tmp/fixture-last-run.json", __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      JSON.pretty_generate(
        start_ts: "2026-04-18T12:00:00.000Z",
        end_ts: "2026-04-18T12:01:00.000Z",
        request_count: 100,
      ) + "\n"
    )
    path
  end

  class FakePg
    def initialize(rows)
      @rows = rows
    end

    def connect(*)
      FakeConnection.new(@rows)
    end
  end

  class FakeConnection
    def initialize(rows)
      @rows = rows
    end

    def exec(*)
      @rows
    end

    def close; end
  end
end
