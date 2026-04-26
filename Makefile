# ABOUTME: Defines local verification and benchmark operator shortcuts.
# ABOUTME: Keeps destructive load commands explicit about their required environment.
.PHONY: load-smoke verify-fixture load-soak test test-load test-adapters test-adapters-fixture-integration test-adapters-demo-integration test-adapters-integration test-workloads load-soak-planetscale

test: test-load test-adapters test-workloads

test-load:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'

test-adapters:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["adapters/rails/test/*_test.rb"].sort.each { |path| load path }'

test-adapters-fixture-integration:
	RUN_RAILS_INTEGRATION=1 BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb --name test_prepare_migrate_load_start_and_stop_against_fixture_app

test-adapters-demo-integration:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres RUN_DB_SPECIALIST_DEMO_INTEGRATION=1 DB_SPECIALIST_DEMO_PATH=/home/bjw/db-specialist-demo BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby adapters/rails/test/integration_test.rb --name test_real_db_specialist_demo_end_to_end

test-adapters-integration: test-adapters-fixture-integration test-adapters-demo-integration

test-workloads:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["workloads/missing_index_todos/test/*_test.rb"].sort.each { |path| load path }'

load-smoke:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load run --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

verify-fixture:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load verify-fixture --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

load-soak:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load soak --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo

load-soak-planetscale:
	@test -n "$$DATABASE_URL" || (echo "DATABASE_URL is required" >&2; exit 1)
	@test -n "$$BENCH_ADAPTER_PG_ADMIN_URL" || (echo "BENCH_ADAPTER_PG_ADMIN_URL is required" >&2; exit 1)
	BENCH_ADAPTER_RESET_STRATEGY=remote bin/load soak --workload missing-index-todos --startup-grace-seconds 60 --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
