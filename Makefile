.PHONY: load-smoke

load-smoke:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkpoint_demo BENCH_ADAPTER_PG_ADMIN_URL=postgres://postgres:postgres@localhost:5432/postgres bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
