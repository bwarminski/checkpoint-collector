# ABOUTME: Verifies the mixed missing-index workload action request shapes.
# ABOUTME: Covers the fixed request paths and bounded-scope inputs for each action.
require "json"

require_relative "../../../load/test/test_helper"
require_relative "../actions/close_todo"
require_relative "../actions/create_todo"
require_relative "../actions/delete_completed_todos"
require_relative "../actions/fetch_counts"
require_relative "../actions/list_open_todos"
require_relative "../actions/list_recent_todos"
require_relative "../actions/search_todos"

class MissingIndexTodosActionsTest < Minitest::Test
  Response = Struct.new(:code, :body)

  def test_actions_issue_expected_requests
    client = FakeClient.new(
      get_responses: {
        "/api/todos?user_id=103&status=open" => Response.new("200", JSON.generate([{ "id" => 123 }]))
      }
    )
    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 1_000 }, seed: 42)

    Load::Workloads::MissingIndexTodos::Actions::ListOpenTodos.new(rng: Random.new(42), ctx: { scale: }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::ListRecentTodos.new(rng: Random.new(42), ctx: { scale: }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::CreateTodo.new(rng: Random.new(42), ctx: { scale: }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::CloseTodo.new(rng: Random.new(42), ctx: { scale: }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos.new(rng: Random.new(42), ctx: { scale: }, client:).call
    Load::Workloads::MissingIndexTodos::Actions::FetchCounts.new(rng: Random.new(42), ctx: {}, client:).call
    Load::Workloads::MissingIndexTodos::Actions::SearchTodos.new(rng: Random.new(42), ctx: { query: "foo", scale: }, client:).call

    assert_equal [
      [:get, "/api/todos?user_id=103&status=open", nil],
      [:get, "/api/todos?user_id=103&status=all&page=1&per_page=50&order=created_desc", nil],
      [:post, "/api/todos", { user_id: 103, title: "load" }],
      [:get, "/api/todos?user_id=103&status=open", nil],
      [:patch, "/api/todos/123", { status: "closed" }],
      [:delete, "/api/todos/completed?user_id=103", nil],
      [:get, "/api/todos/counts", nil],
      [:get, "/api/todos/search?user_id=103&q=foo", nil],
    ], client.requests
  end

  def test_create_todo_samples_user_id_from_user_count
    client = FakeClient.new
    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 3 }, seed: 42)

    Load::Workloads::MissingIndexTodos::Actions::CreateTodo.new(rng: Random.new(42), ctx: { scale: }, client:).call

    assert_equal [[:post, "/api/todos", { user_id: 3, title: "load" }]], client.requests
  end

  def test_delete_completed_todos_is_user_scoped_without_prefetch
    client = FakeClient.new
    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 3 }, seed: 42)

    Load::Workloads::MissingIndexTodos::Actions::DeleteCompletedTodos.new(rng: Random.new(42), ctx: { scale: }, client:).call

    assert_equal [[:delete, "/api/todos/completed?user_id=3", nil]], client.requests
  end

  def test_close_todo_fetches_a_users_open_todos_before_closing_one
    client = FakeClient.new(
      get_responses: {
        "/api/todos?user_id=3&status=open" => Response.new("200", JSON.generate([{ "id" => 17 }, { "id" => 23 }]))
      }
    )
    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 3 }, seed: 42)

    response = Load::Workloads::MissingIndexTodos::Actions::CloseTodo.new(rng: Random.new(42), ctx: { scale: }, client:).call

    assert_equal "200", response.code
    assert_equal [
      [:get, "/api/todos?user_id=3&status=open", nil],
      [:patch, "/api/todos/17", { status: "closed" }],
    ], client.requests
  end

  def test_close_todo_returns_successful_no_op_when_user_has_no_open_todos
    client = FakeClient.new(
      get_responses: {
        "/api/todos?user_id=3&status=open" => Response.new("200", JSON.generate([]))
      }
    )
    scale = Load::Scale.new(rows_per_table: 100_000, extra: { user_count: 3 }, seed: 42)

    response = Load::Workloads::MissingIndexTodos::Actions::CloseTodo.new(rng: Random.new(42), ctx: { scale: }, client:).call

    assert_equal "204", response.code
    assert_equal "", response.body
    assert_equal [[:get, "/api/todos?user_id=3&status=open", nil]], client.requests
  end

  class FakeClient
    attr_reader :requests

    def initialize(get_responses: {}, default_response: Response.new("200", ""))
      @requests = []
      @get_responses = get_responses
      @default_response = default_response
    end

    def get(path)
      @requests << [:get, path, nil]
      @get_responses.fetch(path, @default_response)
    end

    def request(method, path, body: nil, headers: {})
      @requests << [method, path, body]
      @default_response
    end
  end
end
