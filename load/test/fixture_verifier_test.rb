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

  def test_verifier_checks_missing_index_counts_and_search
    client = FakeClient.new(
      "/api/todos/counts" => FakeResponse.new("200", JSON.generate({ "1" => 7, "2" => 3 })),
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
      distinct_queryids_reader: -> { ["users-query", "counts-query"] },
      search_reference_reader: -> { search_reference_plan },
    )

    result = verifier.call(base_url: "http://app.test")

    assert_equal true, result.fetch(:ok)
    assert_equal %w[missing_index counts_n_plus_one search_rewrite], result.fetch(:checks).map { |check| check.fetch(:name) }
    assert_equal 1, stats_reset_calls
    assert_equal ["/api/todos/counts"], client.requests
    assert_equal 2, result.fetch(:checks).fetch(1).fetch(:distinct_queryids)
    assert_equal 2, explain_sqls.length
    assert_includes explain_sqls.first, "status = 'open'"
    assert_includes explain_sqls.last, "title LIKE '%foo%'"
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

  def test_verifier_fails_when_counts_path_has_fewer_than_two_distinct_queryids
    verifier = build_verifier(distinct_queryids_reader: -> { ["counts-query"] })

    error = assert_raises(Load::FixtureVerifier::VerificationError) do
      verifier.call(base_url: "http://app.test")
    end

    assert_includes error.message, "/api/todos/counts"
    assert_includes error.message, "distinct queryids"
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

  private

  def build_verifier(explain_reader: nil, distinct_queryids_reader: nil)
    Load::FixtureVerifier.new(
      workload_name: "missing-index-todos",
      client_factory: ->(*) { counts_client },
      explain_reader: explain_reader || lambda { |sql| sql.include?("status = 'open'") ? missing_index_plan : search_reference_plan },
      stats_reset: -> {},
      distinct_queryids_reader: distinct_queryids_reader || -> { ["users-query", "counts-query"] },
      search_reference_reader: -> { search_reference_plan },
    )
  end

  def counts_client
    FakeClient.new(
      "/api/todos/counts" => FakeResponse.new("200", JSON.generate({ "1" => 7, "2" => 3 })),
    )
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

  def search_reference_path
    File.expand_path("../../fixtures/mixed-todo-app/search-explain.json", __dir__)
  end
end
