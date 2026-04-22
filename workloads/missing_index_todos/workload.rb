# ABOUTME: Defines the missing-index workload used for the todos benchmark path.
# ABOUTME: Declares the fixed scale, weighted actions, and load plan for the run.
require_relative "../../load/lib/load"
require_relative "actions/list_open_todos"

module MissingIndexTodos
  class Workload < Load::Workload
    def name
      "missing-index-todos"
    end

    def scale
      Load::Scale.new(rows_per_table: 10_000_000, open_fraction: 0.002, seed: 42)
    end

    def actions
      [Load::ActionEntry.new(MissingIndexTodos::Actions::ListOpenTodos, 1)]
    end

    def load_plan
      Load::LoadPlan.new(workers: 16, duration_seconds: 60, rate_limit: :unlimited, seed: nil)
    end
  end
end
