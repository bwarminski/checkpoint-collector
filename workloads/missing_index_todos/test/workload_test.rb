# ABOUTME: Verifies the missing-index workload contract and action wiring.
# ABOUTME: Covers the scale, load plan, and mixed action mix.
require_relative "../../../load/test/test_helper"
require_relative "../workload"
require_relative "../actions/list_open_todos"

class MissingIndexTodosWorkloadTest < Minitest::Test
  def test_workload_matches_missing_index_contract
    workload = Load::Workloads::MissingIndexTodos::Workload.new

    assert_equal "missing-index-todos", workload.name
    assert_equal Load::Scale.new(rows_per_table: 100_000, open_fraction: 0.6, seed: 42), workload.scale
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

  def test_list_open_todos_gets_open_status_endpoint
    response = Object.new
    client = FakeClient.new(response)
    action = Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos.new(rng: Random.new(42), ctx: {}, client:)

    assert_equal :list_open_todos, action.name
    assert_same response, action.call
    assert_equal ["/api/todos?status=open"], client.paths
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
end
