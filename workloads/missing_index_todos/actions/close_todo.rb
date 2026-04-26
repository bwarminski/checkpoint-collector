# ABOUTME: Defines the close-todo request used in the mixed missing-index workload.
# ABOUTME: Marks one todo closed through the shared client using a fixture-friendly id.
require "json"

require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CloseTodo < Load::Action
          NoOpResponse = Struct.new(:code, :body)

          def name
            :close_todo
          end

          def call
            todo = open_todos.first
            return NoOpResponse.new("204", "") unless todo

            client.request(:patch, "/api/todos/#{todo.fetch("id")}", body: { status: "closed" })
          end

          private

          def open_todos
            response = client.get("/api/todos?user_id=#{sample_user_id}&status=open")
            JSON.parse(response.body.to_s)
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end
