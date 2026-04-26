# ABOUTME: Defines the delete-completed-todos request used in the mixed missing-index workload.
# ABOUTME: Deletes completed todos with a bounded per-user scope through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class DeleteCompletedTodos < Load::Action
          def name
            :delete_completed_todos
          end

          def call
            client.request(:delete, "/api/todos/completed?user_id=#{user_id}")
          end

          private

          def user_id
            ctx.fetch(:user_id) { sample_user_id }
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
