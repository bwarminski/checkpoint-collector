# ABOUTME: Defines the missing-index workload used for the todos benchmark path.
# ABOUTME: Declares the fixed scale, weighted actions, and load plan for the run.
require_relative "../../load/lib/load"
require_relative "invariant_sampler"
require_relative "verifier"
require_relative "actions/close_todo"
require_relative "actions/create_todo"
require_relative "actions/delete_completed_todos"
require_relative "actions/fetch_counts"
require_relative "actions/list_open_todos"
require_relative "actions/list_recent_todos"
require_relative "actions/search_todos"

module Load
  module Workloads
    module MissingIndexTodos
      class Workload < Load::Workload
        def name
          "missing-index-todos"
        end

        def scale
          Load::Scale.new(rows_per_table: 100_000, seed: 42, extra: { open_fraction: 0.6, user_count: 100 })
        end

        def actions
          [
            Load::ActionEntry.new(Actions::ListOpenTodos, 68),
            Load::ActionEntry.new(Actions::ListRecentTodos, 12),
            Load::ActionEntry.new(Actions::CreateTodo, 7),
            Load::ActionEntry.new(Actions::CloseTodo, 7),
            Load::ActionEntry.new(Actions::DeleteCompletedTodos, 3),
            Load::ActionEntry.new(Actions::FetchCounts, 0),
            Load::ActionEntry.new(Actions::SearchTodos, 3),
          ]
        end

        def load_plan
          Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
        end

        def invariant_sampler(database_url:, pg:)
          rows_per_table = scale.rows_per_table
          Load::Workloads::MissingIndexTodos::InvariantSampler.new(
            pg:,
            database_url:,
            open_floor: (rows_per_table * 0.3).to_i,
            total_floor: (rows_per_table * 0.8).to_i,
            total_ceiling: (rows_per_table * 2.0).to_i,
          )
        end

        def verifier(database_url:, pg:)
          Load::Workloads::MissingIndexTodos::Verifier.new(database_url:, pg:)
        end
      end
    end
  end
end

Load::WorkloadRegistry.register("missing-index-todos", Load::Workloads::MissingIndexTodos::Workload)
