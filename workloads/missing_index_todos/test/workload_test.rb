# ABOUTME: Verifies the missing-index workload contract and action wiring.
# ABOUTME: Covers the scale, load plan, and mixed action mix.
require_relative "../../../load/test/test_helper"
require_relative "../workload"
require_relative "../actions/list_open_todos"

class MissingIndexTodosWorkloadTest < Minitest::Test
  def test_workload_matches_missing_index_contract
    workload = Load::Workloads::MissingIndexTodos::Workload.new

    assert_equal "missing-index-todos", workload.name
    assert_equal Load::Scale.new(rows_per_table: 100_000, extra: { open_fraction: 0.6, user_count: 1_000 }, seed: 42), workload.scale
    assert_equal 1_000, workload.scale.extra.fetch(:user_count)
    assert_equal [
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos, 68),
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::ListRecentTodos, 12),
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::CreateTodo, 7),
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::CloseTodo, 7),
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos, 3),
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::FetchCounts, 2),
      Load::ActionEntry.new(Load::Workloads::MissingIndexTodos::Actions::SearchTodos, 3),
    ], workload.actions
    assert_equal Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil), workload.load_plan
  end

  def test_workload_builds_a_missing_index_invariant_sampler
    workload = Load::Workloads::MissingIndexTodos::Workload.new
    sampler = workload.invariant_sampler(database_url: "postgres://example.test/checkpoint", pg: Object.new)

    assert_instance_of Load::Workloads::MissingIndexTodos::InvariantSampler, sampler
  end

  def test_workload_builds_a_missing_index_fixture_verifier
    workload = Load::Workloads::MissingIndexTodos::Workload.new
    verifier = workload.verifier(database_url: "postgres://example.test/checkpoint", pg: Object.new)

    assert_instance_of Load::FixtureVerifier, verifier
  end

  def test_workload_sampler_applies_rows_per_table_thresholds_to_sample_output
    workload = Load::Workloads::MissingIndexTodos::Workload.new
    pg = FakePg.new(open_count: 100, total_count: 1_000_000)
    sample = workload.invariant_sampler(database_url: "postgres://example.test/checkpoint", pg:).call

    assert_equal true, sample.checks.fetch(0).breach?
    assert_equal true, sample.checks.fetch(1).breach?
  end

  def test_list_open_todos_gets_open_status_endpoint
    response = Object.new
    client = FakeClient.new(response)
    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 1_000 }, seed: 42)
    action = Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos.new(rng: Random.new(42), ctx: { scale: }, client:)

    assert_equal :list_open_todos, action.name
    assert_same response, action.call
    assert_equal ["/api/todos?user_id=103&status=open"], client.paths
  end

  class FakeClient
    attr_reader :paths

    def initialize(response)
      @response = response
      @paths = []
    end

    def get(path)
      @paths << path
      @response
    end
  end

  class FakePg
    attr_reader :connection

    def initialize(open_count:, total_count:)
      @open_count = open_count
      @total_count = total_count
      @connection = nil
    end

    def connect(database_url)
      @connection = FakePgConnection.new(database_url:, open_count: @open_count, total_count: @total_count)
    end
  end

  class FakePgConnection
    def initialize(database_url:, open_count:, total_count:)
      @database_url = database_url
      @open_count = open_count
      @total_count = total_count
    end

    def exec(sql)
      if sql.include?("COUNT(*)") && sql.include?("FROM todos")
        [{ "count" => @open_count.to_s }]
      elsif sql.include?("FROM pg_class")
        [{ "count" => @total_count.to_s }]
      else
        []
      end
    end

    def transaction
      yield self
    end

    def close
      true
    end
  end
end
