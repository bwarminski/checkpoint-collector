# ABOUTME: Defines the create-todo request used in the mixed missing-index workload.
# ABOUTME: Creates a todo through the shared client with a minimal JSON payload.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class CreateTodo < Load::Action
          def name
            :create_todo
          end

          def call
            client.request(:post, "/api/todos", body: payload)
          end

          private

          def payload
            {
              user_id: ctx.fetch(:user_id) { sample_user_id },
              title: ctx.fetch(:title, "load"),
            }
          end

          def sample_user_id
            scale = ctx[:scale]
            return 1 unless scale

            rng.rand(1..scale.rows_per_table)
          end
        end
      end
    end
  end
end
