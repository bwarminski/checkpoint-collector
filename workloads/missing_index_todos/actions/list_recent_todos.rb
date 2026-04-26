# ABOUTME: Defines the recent-todos request used in the mixed missing-index workload.
# ABOUTME: Fetches the recent todos page through the shared client with fixed pagination.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class ListRecentTodos < Load::Action
          def name
            :list_recent_todos
          end

          def call
            client.get("/api/todos?user_id=#{sample_user_id}&status=all&page=1&per_page=50&order=created_desc")
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
