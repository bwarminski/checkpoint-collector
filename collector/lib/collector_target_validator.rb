# ABOUTME: Validates that a collector pass can read a Postgres target and write ClickHouse evidence.
# ABOUTME: Runs a marker query before one collector pass so target validation is deterministic.
require "json"
require "net/http"
require "uri"

class CollectorTargetValidator
  Error = Class.new(StandardError)
  VALIDATION_COMMENT = "collector_target_validation".freeze
  VALIDATION_SQL = "SELECT current_setting('server_version_num') /* #{VALIDATION_COMMENT} */".freeze
  VALIDATION_QUERYIDS_SQL = <<~SQL.freeze
    SELECT DISTINCT queryid::text AS queryid
    FROM pg_stat_statements
    WHERE query = 'SELECT current_setting($1) /* collector_target_validation */'
  SQL
  PG_STAT_STATEMENTS_CHECK_SQL = "SELECT 1 FROM pg_stat_statements LIMIT 1".freeze

  def initialize(postgres_url:, clickhouse_url:, require_stats_only: false, env: ENV, pg: PG, runtime_factory: nil, clickhouse_query: nil)
    @postgres_url = postgres_url
    @clickhouse_url = clickhouse_url
    @require_stats_only = require_stats_only
    @env = env
    @pg = pg
    @runtime_factory = runtime_factory || method(:build_runtime)
    @clickhouse_query = clickhouse_query || method(:query_clickhouse_scalar)
  end

  def call
    validate_config!
    verify_postgres_target!
    collector_state_before = collector_state_count

    run_validation_query
    queryids = validation_queryids
    query_events_before = validation_query_event_count(queryids)
    @runtime_factory.call(postgres_url: @postgres_url, clickhouse_url: @clickhouse_url).run_once_pass

    collector_state_after = collector_state_count
    query_events_after = validation_query_event_count(queryids)
    raise Error, "collector_state did not advance" unless collector_state_after > collector_state_before
    raise Error, "query_events did not capture #{VALIDATION_COMMENT}" unless query_events_after > query_events_before

    {
      "ok" => true,
      "collector_state_before" => collector_state_before,
      "collector_state_after" => collector_state_after,
      "query_events_before" => query_events_before,
      "query_events_after" => query_events_after,
    }
  end

  private

  def validate_config!
    raise Error, "POSTGRES_URL is required" if @postgres_url.to_s.empty?
    raise Error, "CLICKHOUSE_URL is required" if @clickhouse_url.to_s.empty?
    return unless @require_stats_only
    return if @env["COLLECTOR_DISABLE_LOG_INGESTION"].to_s == "1"

    raise Error, "stats-only collector validation requires COLLECTOR_DISABLE_LOG_INGESTION=1"
  end

  def verify_postgres_target!
    with_postgres_connection do |connection|
      connection.exec(PG_STAT_STATEMENTS_CHECK_SQL)
    end
  rescue StandardError => error
    raise Error, "pg_stat_statements is not readable: #{error.message}"
  end

  def run_validation_query
    with_postgres_connection do |connection|
      connection.exec(VALIDATION_SQL)
    end
  end

  def validation_queryids
    rows = with_postgres_connection do |connection|
      connection.exec(VALIDATION_QUERYIDS_SQL)
    end
    queryids = Array(rows).map { |row| row.fetch("queryid").to_s }.reject(&:empty?).uniq
    raise Error, "pg_stat_statements did not expose #{VALIDATION_COMMENT} queryid" if queryids.empty?

    queryids
  end

  def with_postgres_connection
    connection = @pg.connect(@postgres_url)
    yield connection
  ensure
    connection&.close
  end

  def collector_state_count
    clickhouse_scalar("SELECT count() AS value FROM collector_state")
  end

  def validation_query_event_count(queryids)
    escaped_queryids = queryids.map { |queryid| "'#{queryid.gsub("'", "''")}'" }.join(", ")
    clickhouse_scalar(<<~SQL)
      SELECT count() AS value
      FROM query_events
      WHERE queryid IN (#{escaped_queryids})
    SQL
  end

  def clickhouse_scalar(sql)
    @clickhouse_query.call(clickhouse_url: @clickhouse_url, sql: sql).to_i
  rescue StandardError => error
    raise Error, "ClickHouse query failed: #{error.message}"
  end

  def query_clickhouse_scalar(clickhouse_url:, sql:)
    uri = URI.parse(clickhouse_url)
    uri.path = "/" if uri.path.to_s.empty?
    uri.query = URI.encode_www_form(query: "#{sql} FORMAT JSONEachRow")
    response = Net::HTTP.get_response(uri)
    raise "#{response.code} #{response.body}" if response.code.to_i >= 400

    body = response.body.to_s.each_line.first
    JSON.parse(body || "{}").fetch("value")
  end

  def build_runtime(postgres_url:, clickhouse_url:)
    CollectorRuntime.new(
      interval_seconds: 5,
      postgres_url: postgres_url,
      clickhouse_url: clickhouse_url,
    )
  end
end
