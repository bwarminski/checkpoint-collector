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
            todo_id = open_todo_ids.sample(random: rng)
            return NoOpResponse.new("204", "") unless todo_id

            client.request(:patch, "/api/todos/#{todo_id}", body: { status: "closed" })
          end

          private

          def open_todo_ids
            response = client.get("/api/todos?user_id=#{sample_user_id}&status=open")
            JSON.parse(response.body.to_s).fetch("items").map { |todo| todo.fetch("id") }
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
