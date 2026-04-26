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
      ".PHONY: load-smoke verify-fixture load-soak test test-load test-adapters test-adapters-fixture-integration test-adapters-demo-integration test-adapters-integration test-workloads"
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

  def test_makefile_exposes_verify_fixture_and_soak_targets
    makefile = File.read(File.expand_path("../../Makefile", __dir__))

    assert_includes makefile, "verify-fixture:"
    assert_includes makefile, "load-soak:"
  end

  def test_readme_documents_verify_fixture_and_soak_commands
    readme = File.read(File.expand_path("../../README.md", __dir__))

    assert_includes readme, "bin/load verify-fixture"
    assert_includes readme, "bin/load soak"
  end

  def test_planetscale_docs_define_canonical_url_without_makefile_ssl_params
    readme = File.read(File.expand_path("../../README.md", __dir__))
    makefile = File.read(File.expand_path("../../Makefile", __dir__))

    assert_includes readme, "Canonical PlanetScale connection URL format"
    assert_includes readme, "postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt"
    planetscale_target = makefile[/load-soak-planetscale:.*?(?=\n\S|\z)/m]
    refute_includes planetscale_target, "sslrootcert"
    refute_includes planetscale_target, "sslmode"
  end
end
