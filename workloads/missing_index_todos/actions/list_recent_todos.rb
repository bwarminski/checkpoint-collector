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
            client.get("/api/todos?status=all&page=1&per_page=50&order=created_desc")
          end
        end
      end
    end
  end
end
