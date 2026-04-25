# ABOUTME: Verifies the mixed missing-index workload action request shapes.
# ABOUTME: Covers the fixed request paths and bounded-scope inputs for each action.
require_relative "../../../load/test/test_helper"
require_relative "../actions/close_todo"
require_relative "../actions/create_todo"
require_relative "../actions/delete_completed_todos"
require_relative "../actions/fetch_counts"
require_relative "../actions/list_open_todos"
require_relative "../actions/list_recent_todos"
require_relative "../actions/search_todos"

class MissingIndexTodosActionsTest < Minitest::Test
  def test_actions_issue_expected_requests
    client = FakeClient.new

    Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos.new(rng: Random.new(42), ctx: {}, client:).call
    Load::Workloads::MissingIndexTodos::Actions::ListRecentTodos.new(rng: Random.new(42), ctx: {}, client:).call
    Load::Workloads::MissingIndexTodos::Actions::CreateTodo.new(rng: Random.new(42), ctx: {}, client:).call
    Load::Workloads::MissingIndexTodos::Actions::CloseTodo.new(rng: Random.new(42), ctx: { todo_id: 123 }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos.new(rng: Random.new(42), ctx: { user_id: 7 }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::FetchCounts.new(rng: Random.new(42), ctx: {}, client:).call
    Load::Workloads::MissingIndexTodos::Actions::SearchTodos.new(rng: Random.new(42), ctx: { query: "foo" }, client:).call

    assert_equal [
      [:get, "/api/todos?status=open", nil],
      [:get, "/api/todos?status=all&page=1&per_page=50&order=created_desc", nil],
      [:post, "/api/todos", { user_id: 1, title: "load" }],
      [:patch, "/api/todos/123", { status: "closed" }],
      [:delete, "/api/todos/completed", { user_id: 7 }],
      [:get, "/api/todos/counts", nil],
      [:get, "/api/todos/search?q=foo", nil],
    ], client.requests
  end

  class FakeClient
    attr_reader :requests

    def initialize
      @requests = []
    end

    def get(path)
      request(:get, path)
    end

    def request(method, path, body: nil, headers: {})
      @requests << [method, path, body]
      Object.new
    end
  end
end
