# ABOUTME: Verifies named workload registration and lookup for the CLI.
# ABOUTME: Locks the explicit registry contract for workload discovery.
require_relative "test_helper"

class WorkloadRegistryTest < Minitest::Test
  class RegisteredWorkload < Load::Workload
    def name
      "registered-workload"
    end

    def scale
      Load::Scale.new(rows_per_table: 1, seed: 1)
    end

    def actions
      []
    end

    def load_plan
      Load::LoadPlan.new(workers: 1, duration_seconds: 0, rate_limit: :unlimited, seed: nil)
    end
  end

  def setup
    Load::WorkloadRegistry.clear
  end

  def teardown
    Load::WorkloadRegistry.clear
  end

  def test_register_and_fetch_named_workload
    Load::WorkloadRegistry.register("registered-workload", RegisteredWorkload)

    assert_equal RegisteredWorkload, Load::WorkloadRegistry.fetch("registered-workload")
  end

  def test_register_rejects_duplicate_names
    Load::WorkloadRegistry.register("registered-workload", RegisteredWorkload)

    error = assert_raises(Load::WorkloadRegistry::Error) do
      Load::WorkloadRegistry.register("registered-workload", RegisteredWorkload)
    end

    assert_equal "duplicate workload registration: registered-workload", error.message
  end

  def test_register_rejects_non_workload_classes
    error = assert_raises(Load::WorkloadRegistry::Error) do
      Load::WorkloadRegistry.register("bad-workload", String)
    end

    assert_equal "workload \"bad-workload\" must inherit from Load::Workload", error.message
  end
end
