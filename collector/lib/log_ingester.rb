# ABOUTME: Reads PostgreSQL JSON logs and inserts statement rows into ClickHouse.
# ABOUTME: Tracks file offsets across reads and preserves raw log payloads for analysis.
require "json"
require "time"
require_relative "query_comment_parser"

class LogIngester
  def initialize(log_reader:, clickhouse_connection:, state_store:, clock: -> { Time.now.utc }, stderr: $stderr, file_sizer: nil)
    @log_reader = log_reader
    @clickhouse_connection = clickhouse_connection
    @state_store = state_store
    @clock = clock
    @stderr = stderr
    @file_sizer = file_sizer || ->(path) { File.size(path) rescue Float::INFINITY }
    @buffers = {}
  end

  def ingest_file(log_file)
    state = @state_store.load(log_file) || {}
    byte_offset = state.fetch(:byte_offset, 0)

    if byte_offset > 0 && @file_sizer.call(log_file) < byte_offset
      byte_offset = 0
      @buffers[log_file] = ""
    end

    buffered_prefix = @buffers.fetch(log_file, "")
    read_offset = byte_offset + buffered_prefix.bytesize
    chunk = @log_reader.call(log_file, read_offset).to_s
    return if chunk.empty?

    combined = buffered_prefix + chunk
    rows, trailing_fragment, next_offset = build_rows(log_file, byte_offset, combined)
    @buffers[log_file] = trailing_fragment

    @clickhouse_connection.insert("postgres_logs", rows) unless rows.empty?

    collected_at = @clock.call
    file_size_at_last_read = read_offset + chunk.bytesize
    @state_store.save(
      log_file,
      byte_offset: next_offset,
      file_size_at_last_read: file_size_at_last_read,
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

    statement_text = extract_statement_text(payload)
    return nil if statement_text.nil?

    parsed = QueryCommentParser.parse_from_query(statement_text)

    {
      log_file: log_file,
      byte_offset: byte_offset,
      log_timestamp: Time.parse(payload.fetch("timestamp")).utc,
      query_id: query_id.to_s,
      statement_text: statement_text,
      database: payload["dbname"],
      session_id: payload["session_id"],
      comment_metadata: parsed,
      raw_json: raw_json
    }
  end

  def extract_statement_text(payload)
    statement_text = payload["statement"]
    return statement_text unless statement_text.nil?

    message = payload["message"].to_s
    match = message.match(/ statement: (?<statement>.+)\z/m)
    match && match[:statement]
  end

  def log_malformed_line(log_file, byte_offset, raw_json, error)
    @stderr.puts(
      "Skipping malformed log line in #{log_file} at byte #{byte_offset}: #{error.message}; raw=#{raw_json}"
    )
  end
end
