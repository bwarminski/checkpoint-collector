# ABOUTME: Verifies fixture preflight checks for the mixed missing-index workload.
# ABOUTME: Covers missing-index, counts N+1, and search-plan drift assertions.
require "json"
require_relative "test_helper"

class FixtureVerifierTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  class FakeClient
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def get(path)
      @requests << path
      @responses.fetch(path)
    end
  end

  class FakePgConnection
    attr_reader :executed_sqls

    def initialize(result)
      @result = result
      @executed_sqls = []
    end

    def exec(sql)
      @executed_sqls << sql
      @result
    end

    def close
    end
  end

  class FakePg
    def initialize(connection)
      @connection = connection
    end

    def connect(database_url)
      @database_url = database_url
      @connection
    end

    attr_reader :database_url
  end

  def test_verifier_checks_missing_index_counts_and_search
    client = FakeClient.new(
      "/api/todos/counts" => FakeResponse.new("200", JSON.generate(counts_body_for_users(10))),
    )
    explain_sqls = []
    stats_reset_calls = 0
    verifier = Load::FixtureVerifier.new(
      workload_name: "missing-index-todos",
      client_factory: lambda do |base_url|
        assert_equal "http://app.test", base_url
        client
      end,
      explain_reader: lambda do |sql|
        explain_sqls << sql
        sql.include?("status = 'open'") ? missing_index_plan : search_reference_plan
      end,
      stats_reset: -> { stats_reset_calls += 1 },
      counts_calls_reader: -> { 11 },
      search_reference_reader: -> { search_reference_plan },
    )

    result = verifier.call(base_url: "http://app.test")

    assert_equal true, result.fetch(:ok)
    assert_equal %w[missing_index counts_n_plus_one search_rewrite], result.fetch(:checks).map { |check| check.fetch(:name) }
    assert_equal 1, stats_reset_calls
    assert_equal ["/api/todos/counts"], client.requests
    assert_equal 11, result.fetch(:checks).fetch(1).fetch(:calls)
    assert_equal 10, result.fetch(:checks).fetch(1).fetch(:users)
    assert_equal 2, explain_sqls.length
    assert_includes explain_sqls.first, "status = 'open'"
    assert_includes explain_sqls.last, "title LIKE '%foo%'"
  end

  def test_verifier_uses_default_counts_calls_reader
    connection = FakePgConnection.new([{ "calls" => "7" }])
    pg = FakePg.new(connection)
    verifier = Load::FixtureVerifier.new(
      workload_name: "missing-index-todos",
      client_factory: ->(base_url) do
        assert_equal "http://app.test", base_url
        counts_client(counts_body: counts_body_for_users(7))
      end,
      explain_reader: lambda do |sql|
        sql.include?("status = 'open'") ? missing_index_plan : search_reference_plan
      end,
      stats_reset: -> {},
      search_reference_reader: -> { search_reference_plan },
      database_url: "postgres://db.test",
      pg: pg,
    )

    result = verifier.call(base_url: "http://app.test")

    assert_equal [Load::FixtureVerifier::COUNTS_CALLS_SQL], connection.executed_sqls
    assert_equal "postgres://db.test", pg.database_url
    assert_equal 7, result.fetch(:checks).fetch(1).fetch(:calls)
  end

  def test_verifier_fails_when_missing_index_plan_loses_seq_scan
    verifier = build_verifier(
      explain_reader: lambda do |sql|
        sql.include?("status = 'open'") ? missing_index_plan(node_type: "Index Scan") : search_reference_plan
      end,
    )

    error = assert_raises(Load::FixtureVerifier::VerificationError) do
      verifier.call(base_url: "http://app.test")
    end

    assert_includes error.message, "Seq Scan"
    assert_includes error.message, "/api/todos"
  end

  def test_verifier_fails_when_counts_path_does_not_scale_with_users_count
    verifier = build_verifier(counts_calls_reader: -> { 2 }, counts_body: counts_body_for_users(10))

    error = assert_raises(Load::FixtureVerifier::VerificationError) do
      verifier.call(base_url: "http://app.test")
    end

    assert_includes error.message, "/api/todos/counts"
    assert_includes error.message, "10 users"
  end

  def test_verifier_fails_when_search_plan_drifts_from_reference
    verifier = build_verifier(
      explain_reader: lambda do |sql|
        sql.include?("status = 'open'") ? missing_index_plan : drifted_search_plan
      end,
    )

    error = assert_raises(Load::FixtureVerifier::VerificationError) do
      verifier.call(base_url: "http://app.test")
    end

    assert_includes error.message, "/api/todos/search"
    assert_includes error.message, "search"
  end

  def test_verifier_allows_search_plan_when_only_volatile_fields_drift
    verifier = build_verifier(
      explain_reader: lambda do |sql|
        sql.include?("status = 'open'") ? missing_index_plan : search_plan_with_volatile_drift
      end,
    )

    result = verifier.call(base_url: "http://app.test")

    assert_equal "search_rewrite", result.fetch(:checks).last.fetch(:name)
  end

  private

  def build_verifier(explain_reader: nil, counts_calls_reader: nil, counts_body: counts_body_for_users(2))
    Load::FixtureVerifier.new(
      workload_name: "missing-index-todos",
      client_factory: ->(*) { counts_client(counts_body:) },
      explain_reader: explain_reader || lambda { |sql| sql.include?("status = 'open'") ? missing_index_plan : search_reference_plan },
      stats_reset: -> {},
      counts_calls_reader: counts_calls_reader || -> { 3 },
      search_reference_reader: -> { search_reference_plan },
    )
  end

  def counts_client(counts_body:)
    FakeClient.new(
      "/api/todos/counts" => FakeResponse.new("200", JSON.generate(counts_body)),
    )
  end

  def counts_body_for_users(users_count)
    (1..users_count).each_with_object({}) do |user_id, counts|
      counts[user_id.to_s] = user_id
    end
  end

  def missing_index_plan(node_type: "Seq Scan", filter: %(("todos"."status" = 'open'::text)))
    {
      "Node Type" => "Gather",
      "Plans" => [
        {
          "Node Type" => node_type,
          "Relation Name" => "todos",
          "Filter" => filter,
        },
      ],
    }
  end

  def search_reference_plan
    JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan")
  end

  def drifted_search_plan
    {
      "Node Type" => "Limit",
      "Plans" => [
        {
          "Node Type" => "Sort",
          "Plans" => [
            {
              "Node Type" => "Seq Scan",
              "Relation Name" => "todos",
              "Filter" => "((title)::text ~~ '%bar%'::text)",
            },
          ],
        },
      ],
    }
  end

  def search_plan_with_volatile_drift
    {
      "Node Type" => "Limit",
      "Parallel Aware" => true,
      "Async Capable" => true,
      "Startup Cost" => 999.99,
      "Total Cost" => 1000.01,
      "Plan Rows" => 50,
      "Plan Width" => 88,
      "Plans" => [
        {
          "Node Type" => "Sort",
          "Parent Relationship" => "Inner",
          "Parallel Aware" => true,
          "Async Capable" => true,
          "Startup Cost" => 777.77,
          "Total Cost" => 888.88,
          "Plan Rows" => 44,
          "Plan Width" => 66,
          "Sort Key" => ["created_at DESC"],
          "Plans" => [
            {
              "Node Type" => "Seq Scan",
              "Parent Relationship" => "Inner",
              "Parallel Aware" => true,
              "Async Capable" => true,
              "Relation Name" => "todos",
              "Alias" => "todo_items",
              "Startup Cost" => 111.11,
              "Total Cost" => 222.22,
              "Plan Rows" => 33,
              "Plan Width" => 55,
              "Filter" => "((title)::text ~~ '%foo%'::text)",
            },
          ],
        },
      ],
    }
  end

  def search_reference_path
    File.expand_path("../../fixtures/mixed-todo-app/search-explain.json", __dir__)
  end
end
