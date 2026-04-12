# ABOUTME: Reads PostgreSQL JSON logs and inserts statement rows into ClickHouse.
# ABOUTME: Tracks file offsets across reads and preserves raw log payloads for analysis.
require "json"
require "time"
require_relative "query_comment_parser"

class LogIngester
  COMMENT_BLOCK_PATTERN = %r{/\*.*?\*/}m
  COMMENT_METADATA_MARKERS = %w[source_location: source_location=].freeze

  def initialize(log_reader:, clickhouse_connection:, state_store:, clock: -> { Time.now.utc }, stderr: $stderr)
    @log_reader = log_reader
    @clickhouse_connection = clickhouse_connection
    @state_store = state_store
    @clock = clock
    @stderr = stderr
    @buffers = {}
  end

  def ingest_file(log_file)
    state = @state_store.load(log_file) || {}
    byte_offset = state.fetch(:byte_offset, 0)
    buffered_prefix = @buffers.fetch(log_file, "")
    read_offset = byte_offset + buffered_prefix.bytesize
    chunk = @log_reader.call(log_file, read_offset).to_s
    return if chunk.empty?

    combined = buffered_prefix + chunk
    rows, trailing_fragment, next_offset = build_rows(log_file, byte_offset, combined)
    @buffers[log_file] = trailing_fragment

    @clickhouse_connection.insert("postgres_logs", rows) unless rows.empty?

    collected_at = @clock.call
    @state_store.save(
      log_file,
      byte_offset: next_offset,
      file_size_at_last_read: next_offset,
      collected_at: collected_at
    )
  end

  private

  def build_rows(log_file, line_offset, combined)
    lines = combined.split("\n", -1)
    trailing_fragment = lines.pop
    rows = []
    current_offset = line_offset

    lines.each do |line|
      row = build_row(log_file, current_offset, line)
      rows << row if row
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError => error
      log_malformed_line(log_file, current_offset, line, error)
    ensure
      current_offset += line.bytesize + 1
    end

    [rows, trailing_fragment, current_offset]
  end

  def build_row(log_file, byte_offset, raw_json)
    payload = JSON.parse(raw_json)
    query_id = payload["query_id"]
    return nil if query_id.nil?

    statement_text = payload["statement"]
    parsed = QueryCommentParser.parse(extract_comment(statement_text))

    {
      log_file: log_file,
      byte_offset: byte_offset,
      log_timestamp: Time.parse(payload.fetch("timestamp")).utc,
      query_id: query_id.to_s,
      statement_text: statement_text,
      database: payload["dbname"],
      session_id: payload["session_id"],
      source_location: presence(parsed[:source_file]),
      raw_json: raw_json
    }
  end

  def extract_comment(statement_text)
    statement_text.to_s.scan(COMMENT_BLOCK_PATTERN).find do |comment|
      COMMENT_METADATA_MARKERS.any? { |marker| comment.include?(marker) }
    end
  end

  def presence(value)
    value unless value.to_s.empty?
  end

  def log_malformed_line(log_file, byte_offset, raw_json, error)
    @stderr.puts(
      "Skipping malformed log line in #{log_file} at byte #{byte_offset}: #{error.message}; raw=#{raw_json}"
    )
  end
end
