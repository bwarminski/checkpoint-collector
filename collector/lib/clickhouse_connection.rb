# ABOUTME: Sends collected query event rows to ClickHouse over its HTTP interface.
# ABOUTME: Encodes inserts as JSONEachRow so the collector can write without extra gems.
require "json"
require "net/http"
require "uri"

class ClickhouseConnection
  def initialize(base_url:, transport: nil)
    @base_url = base_url
    @transport = transport || method(:perform_request)
  end

  def insert(table, rows)
    return if rows.empty?

    uri = URI.parse("#{@base_url}/")
    uri.query = URI.encode_www_form(query: "INSERT INTO #{table} FORMAT JSONEachRow")

    request = Net::HTTP::Post.new(uri)
    request.body = rows.map { |row| JSON.generate(serialize_row(row)) }.join("\n") + "\n"

    response = @transport.call(uri, request)
    return if response.code.to_i < 400

    raise "ClickHouse insert failed: #{response.code} #{response.body}"
  end

  private

  def perform_request(uri, request)
    Net::HTTP.start(uri.host, uri.port) do |http|
      http.request(request)
    end
  end

  def serialize_row(row)
    row.to_h.transform_values do |value|
      serialize_value(value)
    end
  end

  def serialize_value(value)
    return value.utc.strftime("%Y-%m-%d %H:%M:%S.%L") if value.is_a?(Time)

    value
  end
end
