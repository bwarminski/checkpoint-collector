.PHONY: load-smoke

load-smoke:
	bin/load run --workload workloads/missing_index_todos/workload.rb --adapter adapters/rails/bin/bench-adapter --app-root /home/bjw/db-specialist-demo
