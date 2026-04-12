# ABOUTME: End-to-end integration test for the full collector pipeline.
# ABOUTME: Boots the compose stack, runs real SQL, and verifies ClickHouse row shapes.
#
# What this verifies:
#   - Postgres emits jsonlog entries with statement text embedded in the "message" field
#     (the real format: "duration: X ms  statement: <sql>")
#   - LogIngester extracts statement_text correctly from that format
#   - postgres_logs rows have the expected shape including source_location from query comments
#   - query_events rows carry statement_text from pg_stat_statements
#   - After two collection passes, query_intervals produces non-null avg_exec_time_ms
#
# Requires Docker. Skipped if `docker compose build` has not been run.

import json
import subprocess
import time

import pytest

from tests.conftest import ROOT, compose, wait_healthy, clickhouse_query, postgres_exec

COLLECTOR_INTERVAL = 5  # seconds, matches COLLECTOR_INTERVAL_SECONDS default


def stack_is_buildable() -> bool:
    result = subprocess.run(
        ["docker", "compose", "config", "--quiet"],
        cwd=ROOT,
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


@pytest.fixture(scope="module")
def running_stack():
    if not stack_is_buildable():
        pytest.skip("docker compose config failed — stack not available")

    compose("build", "--quiet")
    compose("up", "-d", "postgres", "clickhouse")

    wait_healthy("postgres")
    wait_healthy("clickhouse")

    # Start collector after dependencies are healthy
    compose("up", "-d", "collector")

    yield

    compose("down", "-v")


def wait_for_rows(table: str, min_count: int = 1, timeout: int = 30) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        count = clickhouse_query(f"SELECT count() FROM {table}")
        if int(count) >= min_count:
            return
        time.sleep(1)
    actual = clickhouse_query(f"SELECT count() FROM {table}")
    raise AssertionError(f"Expected >= {min_count} rows in {table}, got {actual} after {timeout}s")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_postgres_logs_ingested_with_statement_text_from_message_field(running_stack):
    """
    Real Postgres jsonlog embeds the statement inside the 'message' field as:
      "duration: X ms  statement: <sql>"
    rather than a bare 'statement' key. The ingester must extract it correctly.
    """
    postgres_exec(
        "SELECT count(*) FROM pg_stat_statements "
        "/*source_location:/app/models/todo.rb:10*/;"
    )

    wait_for_rows("postgres_logs", min_count=1, timeout=30)

    rows_json = clickhouse_query(
        "SELECT statement_text, source_location, database "
        "FROM postgres_logs "
        "WHERE statement_text LIKE '%pg_stat_statements%' "
        "AND statement_text LIKE '%source_location%' "
        "LIMIT 1 FORMAT JSON"
    )
    assert rows_json, "No matching row found in postgres_logs"
    row = json.loads(rows_json)["data"][0]

    assert "pg_stat_statements" in row["statement_text"]
    assert "source_location:/app/models/todo.rb:10" in row["statement_text"]
    assert row["source_location"] == "/app/models/todo.rb:10"
    assert row["database"] == "checkpoint_demo"


def test_postgres_logs_row_has_required_columns(running_stack):
    """
    Verify the full column shape of postgres_logs rows — guards schema regressions.
    """
    wait_for_rows("postgres_logs", min_count=1)

    describe = clickhouse_query(
        "SELECT name FROM system.columns "
        "WHERE table = 'postgres_logs' "
        "ORDER BY name FORMAT JSONCompact"
    )
    columns = {row[0] for row in json.loads(describe)["data"]}

    assert "log_file" in columns
    assert "byte_offset" in columns
    assert "log_timestamp" in columns
    assert "query_id" in columns
    assert "statement_text" in columns
    assert "database" in columns
    assert "session_id" in columns
    assert "source_location" in columns
    assert "raw_json" in columns


def test_query_events_populated_with_statement_text(running_stack):
    """
    query_events should carry statement_text from pg_stat_statements.query —
    not a fingerprint alias or a sampled active-query guess.
    """
    wait_for_rows("query_events", min_count=1, timeout=30)

    result = clickhouse_query(
        "SELECT count() FROM query_events WHERE statement_text IS NOT NULL"
    )
    assert int(result) > 0, "No query_events rows have statement_text"

    # fingerprint and sample_query must not exist in the schema
    columns_json = clickhouse_query(
        "SELECT name FROM system.columns "
        "WHERE table = 'query_events' FORMAT JSONCompact"
    )
    columns = {row[0] for row in json.loads(columns_json)["data"]}
    assert "fingerprint" not in columns, "fingerprint column should have been removed"
    assert "sample_query" not in columns, "sample_query column should have been removed"


def test_query_intervals_produces_avg_exec_time_after_two_passes(running_stack):
    """
    query_intervals derives avg_exec_time_ms from delta counts across consecutive
    snapshots. It should be non-null and positive after two collection passes.
    """
    # Ensure at least two snapshots exist for the same queryid
    # by running a recognisable query, waiting for one pass, running it again,
    # then waiting for the second pass to complete.
    tag = "/*integration_test_marker*/"
    postgres_exec(f"SELECT 1 AS integration_marker {tag};")
    time.sleep(COLLECTOR_INTERVAL + 2)
    postgres_exec(f"SELECT 1 AS integration_marker {tag};")
    time.sleep(COLLECTOR_INTERVAL + 2)

    result = clickhouse_query(
        "SELECT count() FROM query_intervals WHERE avg_exec_time_ms IS NOT NULL"
    )
    assert int(result) > 0, "No query_intervals rows with non-null avg_exec_time_ms"


def test_non_statement_jsonlog_entries_do_not_appear_in_postgres_logs(running_stack):
    """
    Postgres emits many non-statement log entries (autovacuum, checkpoint, connection
    events). These have query_id=0 or no extractable statement. None should appear
    in postgres_logs.
    """
    wait_for_rows("postgres_logs", min_count=1)

    # All rows must have non-empty statement_text (the ingester filters everything else)
    empty_count = clickhouse_query(
        "SELECT count() FROM postgres_logs WHERE statement_text IS NULL OR statement_text = ''"
    )
    assert int(empty_count) == 0, (
        f"Found {empty_count} postgres_logs rows with null/empty statement_text — "
        "non-statement entries leaked through the filter"
    )


def test_source_location_round_trips_through_full_pipeline(running_stack):
    """
    A Rails-style query comment survives Postgres logging, ingestion, and
    ClickHouse storage with the source path intact.
    """
    unique_path = "/app/controllers/integration_test_controller.rb:99"
    postgres_exec(
        f"SELECT 1 /*application:test,source_location:{unique_path}*/;"
    )

    deadline = time.time() + 30
    found = False
    while time.time() < deadline:
        result = clickhouse_query(
            f"SELECT count() FROM postgres_logs "
            f"WHERE source_location = '{unique_path}'"
        )
        if int(result) > 0:
            found = True
            break
        time.sleep(1)

    assert found, f"source_location '{unique_path}' not found in postgres_logs after 30s"
