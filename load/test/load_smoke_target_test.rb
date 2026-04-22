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
      "bin/load run --workload workloads/missing_index_todos/workload.rb"
  end
end
