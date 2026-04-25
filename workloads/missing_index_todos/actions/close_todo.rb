# ABOUTME: Defines the close-todo request used in the mixed missing-index workload.
# ABOUTME: Marks one todo closed through the shared client using a fixture-friendly id.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CloseTodo < Load::Action
          def name
            :close_todo
          end

          def call
            client.request(:patch, "/api/todos/#{todo_id}", body: { status: "closed" })
          end

          private

          def todo_id
            ctx.fetch(:todo_id) { sample_todo_id }
          end

          def sample_todo_id
            scale = ctx[:scale]
            return 1 unless scale

            rng.rand(1..scale.rows_per_table)
          end
        end
      end
    end
  end
end
