# ABOUTME: Verifies the missing-index oracle checks EXPLAIN and ClickHouse evidence.
# ABOUTME: Covers tree-walking, queryid polling, and timeout failures for the workload-local oracle.
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require_relative "../../../load/test/test_helper"
require_relative "../oracle"

class MissingIndexTodosOracleTest < Minitest::Test
  def test_oracle_tree_walk_finds_seq_scan_under_wrapper_nodes
    run_dir = write_run_record(query_ids: ["111", "222"])
    explain_rows = [
      {
        "QUERY PLAN" => JSON.generate(
          [
            {
              "Plan" => {
                "Node Type" => "Gather",
                "Plans" => [
                  {
                    "Node Type" => "Limit",
                    "Plans" => [
                      {
                        "Node Type" => "Seq Scan",
                        "Relation Name" => "todos",
                      },
                    ],
                  },
                ],
              },
            },
          ]
        ),
      },
    ]
    clickhouse_calls = []
    oracle = Load::Workloads::MissingIndexTodos::Oracle.new(
      pg: FakePg.new(explain_rows),
      clickhouse_query: lambda do |window:, queryids:, clickhouse_url:|
        clickhouse_calls << { window:, queryids:, clickhouse_url: }
        { "total_exec_count" => "600", "mean_exec_time_ms" => "42.3" }
      end,
      clickhouse_topn_query: ->(**) { [{ "queryid" => "111", "total_exec_time_ms_estimate" => "900.0" }] },
      sleeper: ->(*) {},
    )

    result = oracle.call(
      run_dir:,
      database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
      clickhouse_url: "http://clickhouse:8123",
    )

    assert_equal "Seq Scan", result.fetch(:plan).fetch("Node Type")
    assert_equal 600, result.fetch(:clickhouse).fetch("total_exec_count")
    assert_equal ["111", "222"], clickhouse_calls.first.fetch(:queryids)
    assert_equal "http://clickhouse:8123", clickhouse_calls.first.fetch(:clickhouse_url)
  end

  def test_oracle_falls_back_to_pg_stat_statements_queryids_when_run_record_lacks_them
    run_dir = write_run_record
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
    pg = FakePg.new(
      explain_rows,
      {
        [%(SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = $1), [%(SELECT "todos".* FROM "todos" WHERE "todos"."status" = $1)]] => [{ "queryid" => "111" }],
        [%(SELECT DISTINCT queryid::text AS queryid FROM pg_stat_statements WHERE query = $1), [%(SELECT "todos".* FROM "todos" WHERE "todos"."status" = 'open')]] => [{ "queryid" => "222" }],
      },
    )
    observed_queryids = nil
    oracle = Load::Workloads::MissingIndexTodos::Oracle.new(
      pg:,
      clickhouse_query: lambda do |window:, queryids:, clickhouse_url:|
        observed_queryids = queryids
        { "total_exec_count" => "600", "mean_exec_time_ms" => "42.3" }
      end,
      clickhouse_topn_query: ->(**) { [{ "queryid" => "111", "total_exec_time_ms_estimate" => "900.0" }] },
      sleeper: ->(*) {},
    )

    result = oracle.call(
      run_dir:,
      database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
      clickhouse_url: "http://clickhouse:8123",
    )

    assert_equal 600, result.fetch(:clickhouse).fetch("total_exec_count")
    assert_equal ["111", "222"], observed_queryids
  end

  def test_oracle_fails_when_plan_relation_node_is_index_scan
    run_dir = write_run_record(query_ids: ["111"])
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
    oracle = Load::Workloads::MissingIndexTodos::Oracle.new(
      pg: FakePg.new(explain_rows),
      clickhouse_query: ->(**) { { "total_exec_count" => "600" } },
      sleeper: ->(*) {},
    )

    error = assert_raises(Load::Workloads::MissingIndexTodos::Oracle::Failure) do
      oracle.call(
        run_dir:,
        database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
        clickhouse_url: "http://clickhouse:8123",
      )
    end

    assert_equal "FAIL: explain (expected Seq Scan, got Index Scan)", error.message
  end

  def test_oracle_builds_clickhouse_query_from_queryids_not_sql_like
    oracle = Load::Workloads::MissingIndexTodos::Oracle.new(
      pg: FakePg.new([]),
      clickhouse_query: ->(**) { raise "not used" },
      sleeper: ->(*) {},
    )

    sql = oracle.send(
      :build_clickhouse_sql,
      window: {
        "start_ts" => "2026-04-21T00:00:00Z",
        "end_ts" => "2026-04-21T00:05:00Z",
      },
      queryids: ["111", "222"]
    )

    assert_includes sql, "queryid IN ('111', '222')"
    refute_includes sql, "LIKE"
  end

  def test_oracle_polls_clickhouse_until_total_exec_count_threshold_is_met
    run_dir = write_run_record(query_ids: ["111", "222"])
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
      { "total_exec_count" => "250", "mean_exec_time_ms" => "41.0" },
      { "total_exec_count" => "550", "mean_exec_time_ms" => "42.3" },
    ]
    sleeps = []
    oracle = Load::Workloads::MissingIndexTodos::Oracle.new(
      pg: FakePg.new(explain_rows),
      clickhouse_query: ->(**) { snapshots.shift },
      clickhouse_topn_query: ->(**) { [{ "queryid" => "111", "total_exec_time_ms_estimate" => "900.0" }] },
      sleeper: ->(seconds) { sleeps << seconds },
    )

    result = oracle.call(
      run_dir:,
      database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
      clickhouse_url: "http://clickhouse:8123",
    )

    assert_equal 550, result.fetch(:clickhouse).fetch("total_exec_count")
    assert_equal [1], sleeps
  end

  def test_oracle_passes_when_primary_query_dominates_by_at_least_three_x
    oracle = build_dominance_oracle(
      clickhouse_topn_rows: [
        { "queryid" => "primary", "total_calls" => "70000", "total_exec_time_ms_estimate" => "900.0" },
        { "queryid" => "other", "total_calls" => "5000", "total_exec_time_ms_estimate" => "250.0" },
      ],
    )

    result = oracle.call(
      run_dir: write_run_record(query_ids: ["primary"]),
      database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
      clickhouse_url: "http://clickhouse:8123",
    )

    assert_includes result.fetch(:dominance).fetch("message"), "dominance"
    assert_match(/3\.6x/, result.fetch(:dominance).fetch("message"))
  end

  def test_oracle_fails_when_primary_is_below_three_x_dominance_margin
    oracle = build_dominance_oracle(
      clickhouse_topn_rows: [
        { "queryid" => "primary", "total_calls" => "70000", "total_exec_time_ms_estimate" => "900.0" },
        { "queryid" => "other", "total_calls" => "5000", "total_exec_time_ms_estimate" => "400.0" },
      ],
    )

    error = assert_raises(Load::Workloads::MissingIndexTodos::Oracle::Failure) do
      oracle.call(
        run_dir: write_run_record(query_ids: ["primary"]),
        database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
        clickhouse_url: "http://clickhouse:8123",
      )
    end

    assert_includes error.message, "3x"
    assert_match(/2\.25x/, error.message)
  end

  def test_oracle_passes_dominance_when_there_is_no_challenger
    oracle = build_dominance_oracle(
      clickhouse_topn_rows: [
        { "queryid" => "primary", "total_calls" => "70000", "total_exec_time_ms_estimate" => "900.0" },
      ],
    )

    result = oracle.call(
      run_dir: write_run_record(query_ids: ["primary"]),
      database_url: "postgresql://postgres:postgres@localhost:5432/fixture_01",
      clickhouse_url: "http://clickhouse:8123",
    )

    assert_includes result.fetch(:dominance).fetch("message"), "no challenger"
  end

  def test_run_exits_one_and_prints_clear_message_on_clickhouse_timeout
    run_dir = write_run_record(query_ids: ["111"])
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
    clock = AdvancingClock.new(Time.utc(2026, 4, 21, 0, 0, 0))
    stderr = StringIO.new
    oracle = Load::Workloads::MissingIndexTodos::Oracle.new(
      stderr:,
      pg: FakePg.new(explain_rows),
      clickhouse_query: ->(**) { { "total_exec_count" => "10", "mean_exec_time_ms" => "0.0" } },
      clock: -> { clock.now },
      sleeper: ->(seconds) { clock.advance_by(seconds) },
    )

    error = assert_raises(SystemExit) do
      oracle.run(
        [
          run_dir,
          "--database-url", "postgresql://postgres:postgres@localhost:5432/fixture_01",
          "--clickhouse-url", "http://clickhouse:8123",
          "--timeout-seconds", "2",
        ]
      )
    end

    assert_equal 1, error.status
    assert_includes stderr.string, "FAIL: clickhouse (saw 10 calls before timeout)"
  end

  private

  def build_dominance_oracle(clickhouse_topn_rows:)
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

    Load::Workloads::MissingIndexTodos::Oracle.new(
      pg: FakePg.new(explain_rows),
      clickhouse_query: ->(**) { { "total_exec_count" => "600", "mean_exec_time_ms" => "42.3" } },
      clickhouse_topn_query: lambda do |window:, clickhouse_url:|
        assert_equal "2026-04-21T00:00:00Z", window.fetch("start_ts")
        assert_equal "2026-04-21T00:05:00Z", window.fetch("end_ts")
        assert_equal "http://clickhouse:8123", clickhouse_url
        clickhouse_topn_rows
      end,
      sleeper: ->(*) {},
    )
  end

  def write_run_record(query_ids: nil)
    dir = Dir.mktmpdir
    FileUtils.mkdir_p(dir)
    payload = {
      window: {
        start_ts: "2026-04-21T00:00:00Z",
        end_ts: "2026-04-21T00:05:00Z",
      },
      workload: {},
    }
    payload[:workload][:oracle] = { query_ids: query_ids } if query_ids
    File.write(
      File.join(dir, "run.json"),
      JSON.pretty_generate(payload) + "\n"
    )
    dir
  end

  class FakePg
    def initialize(rows, exec_params_rows = {})
      @rows = rows
      @exec_params_rows = exec_params_rows
    end

    def connect(*)
      FakeConnection.new(@rows, @exec_params_rows)
    end
  end

  class FakeConnection
    def initialize(rows, exec_params_rows)
      @rows = rows
      @exec_params_rows = exec_params_rows
    end

    def exec(*)
      @rows
    end

    def exec_params(sql, params)
      @exec_params_rows.fetch([sql, params], [])
    end

    def close; end
  end

  class AdvancingClock
    attr_reader :now

    def initialize(now)
      @now = now
    end

    def advance_by(seconds)
      @now += seconds
    end
  end
end
