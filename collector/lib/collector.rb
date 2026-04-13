# ABOUTME: Polls Postgres statement stats and shapes rows for ClickHouse inserts.
# ABOUTME: Parses query text for source metadata in Rails query comments.
require "time"
require_relative "query_comment_parser"

class Collector
  STATS_SQL = <<~SQL.freeze
    SELECT
      dbid,
      userid,
      toplevel,
      queryid,
      calls,
      total_exec_time,
      min_exec_time,
      max_exec_time,
      mean_exec_time,
      stddev_exec_time,
      query,
      rows,
      shared_blks_hit,
      shared_blks_read,
      local_blks_hit,
      local_blks_read,
      temp_blks_read,
      temp_blks_written
    FROM pg_stat_statements
  SQL
  INFO_SQL = "SELECT dealloc, stats_reset FROM pg_stat_statements_info".freeze
  BLOCK_COUNTER_KEYS = %w[shared_blks_hit shared_blks_read local_blks_hit local_blks_read temp_blks_read temp_blks_written].freeze

  def initialize(stats_connection: nil, clickhouse_connection: nil, clock: -> { Time.now.utc })
    @stats_connection = stats_connection
    @clickhouse_connection = clickhouse_connection
    @clock = clock
  end

  def run_once
    return [] unless @stats_connection

    stats_rows = Array(@stats_connection.exec(STATS_SQL))
    info_row = Array(@stats_connection.exec(INFO_SQL)).first
    if stats_rows.empty?
      if info_row
        collected_at = @clock.call
        @clickhouse_connection&.insert("collector_state", [build_state_row(info_row, collected_at)])
      end
      return []
    end

    collected_at = @clock.call
    rows = stats_rows.map do |stats_row|
      build_row(stats_row, collected_at)
    end

    @clickhouse_connection&.insert("query_events", rows)
    @clickhouse_connection&.insert("collector_state", [build_state_row(info_row, collected_at)]) if info_row
    rows
  end

  private

  def build_row(stats_row, collected_at)
    queryid = stats_row.fetch("queryid").to_s
    statement_text = stats_row.fetch("query", nil)
    parsed = QueryCommentParser.parse_from_query(statement_text)

    {
      collected_at: collected_at,
      dbid: stats_row.fetch("dbid", 0).to_i,
      userid: stats_row.fetch("userid", 0).to_i,
      toplevel: toplevel_value(stats_row.fetch("toplevel", nil)),
      queryid: queryid,
      statement_text: statement_text,
      comment_metadata: parsed,
      total_exec_count: stats_row.fetch("calls").to_i,
      total_exec_time_ms: stats_row.fetch("total_exec_time", 0).to_f,
      min_exec_time_ms: stats_row.fetch("min_exec_time", 0).to_f,
      max_exec_time_ms: stats_row.fetch("max_exec_time", 0).to_f,
      mean_exec_time_ms: stats_row.fetch("mean_exec_time").to_f,
      stddev_exec_time_ms: stats_row.fetch("stddev_exec_time", 0).to_f,
      # pg_stat_statements.rows reports rows returned or affected, not rows visited.
      rows_returned_or_affected: stats_row.fetch("rows", 0).to_i,
      shared_blks_hit: stat_value(stats_row, "shared_blks_hit"),
      shared_blks_read: stat_value(stats_row, "shared_blks_read"),
      local_blks_hit: stat_value(stats_row, "local_blks_hit"),
      local_blks_read: stat_value(stats_row, "local_blks_read"),
      temp_blks_read: stat_value(stats_row, "temp_blks_read"),
      temp_blks_written: stat_value(stats_row, "temp_blks_written"),
      total_block_accesses: total_block_accesses(stats_row)
    }
  end

  def build_state_row(info_row, collected_at)
    {
      collected_at: collected_at,
      dealloc: info_row.fetch("dealloc").to_i,
      stats_reset: format_stats_reset(info_row.fetch("stats_reset"))
    }
  end

  def format_stats_reset(value)
    return nil unless value
    # Postgres returns timestamptz with microseconds and tz offset.
    # ClickHouse DateTime column accepts "YYYY-MM-DD HH:MM:SS" only.
    Time.parse(value.to_s).utc.strftime("%Y-%m-%d %H:%M:%S")
  rescue ArgumentError
    nil
  end

  def stat_value(stats_row, key)
    stats_row.fetch(key, 0).to_i
  end

  def total_block_accesses(stats_row)
    BLOCK_COUNTER_KEYS.sum { |key| stat_value(stats_row, key) }
  end

  def toplevel_value(value)
    value == true || value.to_s == "t"
  end
end
