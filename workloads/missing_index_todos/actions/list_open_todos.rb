# ABOUTME: Defines the open-todos request used to trigger the missing-index workload.
# ABOUTME: Executes the current status-filtered todos endpoint through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListOpenTodos < Load::Action
          def name
            :list_open_todos
          end

          def call
            client.get("/api/todos?user_id=#{sample_user_id}&status=open")
          end

          private

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end
