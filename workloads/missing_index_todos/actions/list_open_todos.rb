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
            client.get("/api/todos?status=open")
          end
        end
      end
    end
  end
end
