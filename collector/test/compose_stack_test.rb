# ABOUTME: Verifies the collector compose stack matches the supported local runtime.
# ABOUTME: Guards the collector services against reintroducing dead Redpanda wiring.
require "minitest/autorun"

class ComposeStackTest < Minitest::Test
  def test_clickhouse_bootstrap_mentions_interval_and_state_tables
    sql_files = Dir[File.expand_path("../db/clickhouse/*.sql", __dir__)].map { |path| File.basename(path) }

    assert_includes sql_files, "002_collector_state.sql"
    assert_includes sql_files, "003_query_intervals.sql"
    assert_includes sql_files, "004_reset_query_analytics.sql"
    refute_includes sql_files, "002_query_fingerprints.sql"
    refute_includes sql_files, "003_top_offenders_mv.sql"
    refute_includes sql_files, "004_reset_query_fingerprints.sql"
  end

  def test_compose_stack_schema_contract_mentions_collector_state_and_query_intervals
    reset_sql = File.read(File.expand_path("../db/clickhouse/004_reset_query_analytics.sql", __dir__))

    assert_includes reset_sql, "collector_state"
    assert_includes reset_sql, "query_intervals"
  end

  def test_collector_stack_no_longer_mentions_redpanda
    compose = File.read(File.expand_path("../../docker-compose.yml", __dir__))

    refute_includes compose, "redpanda:"
    refute_includes compose, "REDPANDA_BROKERS"
  end

  def test_collector_runs_direct_scheduler_command
    compose = File.read(File.expand_path("../../docker-compose.yml", __dir__))

    assert_includes compose, 'command: ["bundle", "exec", "ruby", "bin/collector"]'
    refute_includes compose, 'command: ["bash", "-lc", "while true; do bundle exec ruby bin/collector; sleep ${COLLECTOR_INTERVAL_SECONDS:-5}; done"]'
  end

  def test_collector_image_no_longer_installs_redpanda_native_dependencies
    dockerfile = File.read(File.expand_path("../Dockerfile", __dir__))

    refute_includes dockerfile, "librdkafka-dev"
  end

  def test_postgres_image_bootstraps_init_scripts
    dockerfile = File.read(File.expand_path("../../postgres/Dockerfile", __dir__))

    assert_includes dockerfile, "FROM postgres:16"
    assert_includes dockerfile, "COPY init/ /docker-entrypoint-initdb.d/"
  end

  def test_redpanda_consumer_runtime_is_removed
    refute File.exist?(File.expand_path("../lib/redpanda_consumer.rb", __dir__))
  end

  def test_postgres_runtime_command_enables_json_logging_on_every_start
    compose = File.read(File.expand_path("../../docker-compose.yml", __dir__))

    assert_includes compose, 'command: ["postgres", "-c", "shared_preload_libraries=pg_stat_statements", "-c", "compute_query_id=on", "-c", "logging_collector=on", "-c", "log_destination=jsonlog", "-c", "log_directory=/var/log/postgresql", "-c", "log_filename=postgresql", "-c", "log_min_duration_statement=0"]'
  end

  def test_collector_mounts_only_postgres_log_volume
    compose = File.read(File.expand_path("../../docker-compose.yml", __dir__))

    assert_includes compose, "- postgres_logs:/var/log/postgresql"
    assert_includes compose, "- postgres_logs:/var/log/postgresql:ro"
    refute_includes compose, "- postgres_data:/var/lib/postgresql/data:ro"
  end
end
