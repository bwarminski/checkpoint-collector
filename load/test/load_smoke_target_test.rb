# ABOUTME: Verifies the repository smoke target runs the load runner entrypoint.
# ABOUTME: Locks the documented workload and adapter command into the Makefile.
require_relative "test_helper"

class LoadSmokeTargetTest < Minitest::Test
  def test_makefile_exposes_load_smoke_target
    makefile = File.read(File.expand_path("../../Makefile", __dir__))

    assert_includes makefile, ".PHONY: load-smoke"
    assert_includes makefile, "DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo"
    assert_includes makefile, "BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres"
    assert_includes makefile,
      "bin/load run --workload missing-index-todos"
  end

  def test_makefile_exposes_adapter_integration_target
    makefile = File.read(File.expand_path("../../Makefile", __dir__))

    assert_includes makefile,
      ".PHONY: load-smoke test test-load test-adapters test-adapters-fixture-integration test-adapters-demo-integration test-adapters-integration test-workloads"
    assert_includes makefile, "test-adapters-integration: test-adapters-fixture-integration test-adapters-demo-integration"
    assert_includes makefile, "test-adapters-fixture-integration:"
    assert_includes makefile, "test-adapters-demo-integration:"
    assert_includes makefile, "RUN_RAILS_INTEGRATION=1"
    assert_includes makefile, "test-adapters-integration:"
    assert_includes makefile, "RUN_DB_SPECIALIST_DEMO_INTEGRATION=1"
    assert_includes makefile, "DB_SPECIALIST_DEMO_PATH=/home/bjw/db-specialist-demo"
    assert_includes makefile, "DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo"
    assert_includes makefile, "BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres"
  end
end
