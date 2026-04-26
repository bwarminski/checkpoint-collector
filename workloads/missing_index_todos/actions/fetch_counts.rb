# ABOUTME: Defines the counts request used in the mixed missing-index workload.
# ABOUTME: Fetches aggregate todo counts through the shared client.
require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class FetchCounts < Load::Action
          def name
            :fetch_counts
          end

          def call
            client.get("/api/todos/counts")
          end
        end
      end
    end
  end
end
