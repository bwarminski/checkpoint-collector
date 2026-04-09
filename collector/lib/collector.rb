# ABOUTME: Polls Postgres statement stats and shapes rows for ClickHouse inserts.
# ABOUTME: Enriches sampled SQL with source metadata parsed from Rails query comments.
require_relative "query_comment_parser"

class Collector
  STATS_SQL = "SELECT queryid, calls, mean_exec_time, rows, shared_blks_hit, shared_blks_read, local_blks_hit, local_blks_read, temp_blks_read, temp_blks_written FROM pg_stat_statements".freeze
  BLOCK_COUNTER_KEYS = [
    "shared_blks_hit",
    "shared_blks_read",
    "local_blks_hit",
    "local_blks_read",
    "temp_blks_read",
    "temp_blks_written"
  ].freeze
  COMMENT_BLOCK_PATTERN = %r{/\*.*?\*/}m
  COMMENT_METADATA_MARKERS = [
    "source_location:",
    "source_location="
  ].freeze

  def initialize(stats_connection: nil, clickhouse_connection: nil, sample_query_lookup: nil, clock: -> { Time.now.utc })
    @stats_connection = stats_connection
    @clickhouse_connection = clickhouse_connection
    @sample_query_lookup = sample_query_lookup
    @clock = clock
  end

  def run_once
    return [] unless @stats_connection

    stats_rows = Array(@stats_connection.exec(STATS_SQL))
    return [] if stats_rows.empty?

    collected_at = @clock.call
    rows = stats_rows.map do |stats_row|
      build_row(stats_row, collected_at)
    end

    @clickhouse_connection&.insert("query_events", rows)
    rows
  end

  private

  def build_row(stats_row, collected_at)
    queryid = stats_row.fetch("queryid").to_s
    sample_query = @sample_query_lookup&.find_for(queryid)
    parsed = QueryCommentParser.parse(extract_comment(sample_query))

    {
      collected_at: collected_at,
      fingerprint: queryid,
      source_file: presence(parsed[:source_file]),
      sample_query: sample_query,
      total_exec_count: stats_row.fetch("calls").to_i,
      mean_exec_time_ms: stats_row.fetch("mean_exec_time").to_f,
      # pg_stat_statements.rows reports rows returned or affected, not rows visited.
      rows_returned_or_affected: stats_row.fetch("rows", 0).to_i,
      shared_blks_hit: stat_value(stats_row, "shared_blks_hit"),
      shared_blks_read: stat_value(stats_row, "shared_blks_read"),
      local_blks_hit: stat_value(stats_row, "local_blks_hit"),
      local_blks_read: stat_value(stats_row, "local_blks_read"),
      temp_blks_read: stat_value(stats_row, "temp_blks_read"),
      temp_blks_written: stat_value(stats_row, "temp_blks_written"),
      total_block_accesses: total_block_accesses(stats_row),
      mean_block_accesses_per_call: mean_block_accesses_per_call(stats_row)
    }
  end

  def stat_value(stats_row, key)
    stats_row.fetch(key, 0).to_i
  end

  def total_block_accesses(stats_row)
    BLOCK_COUNTER_KEYS.sum { |key| stat_value(stats_row, key) }
  end

  def mean_block_accesses_per_call(stats_row)
    calls = stats_row.fetch("calls").to_i
    calls.zero? ? 0.0 : total_block_accesses(stats_row).to_f / calls
  end

  def extract_comment(sample_query)
    sample_query.to_s.scan(COMMENT_BLOCK_PATTERN).find do |comment|
      COMMENT_METADATA_MARKERS.any? { |marker| comment.include?(marker) }
    end
  end

  def presence(value)
    value unless value.to_s.empty?
  end
end
