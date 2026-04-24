.PHONY: load-smoke test test-load test-adapters test-workloads

test: test-load test-adapters test-workloads

test-load:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["load/test/*_test.rb"].sort.each { |path| load path }'

test-adapters:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["adapters/rails/test/*_test.rb"].sort.each { |path| load path }'

test-workloads:
	BUNDLE_GEMFILE=collector/Gemfile bundle exec ruby -e 'Dir["workloads/missing_index_todos/test/*_test.rb"].sort.each { |path| load path }'

load-smoke:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load run --workload missing-index-todos --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
