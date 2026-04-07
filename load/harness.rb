# ABOUTME: Sends repeatable requests to the demo app endpoints.
# ABOUTME: Cycles through the same four request paths used to verify query volume.
require "net/http"
require "uri"

class Harness
  def initialize(base_url:, rate: 10)
    @base_url = base_url
    @rate = rate
  end

  def request_paths
    ["/todos", "/todos?q=task", "/todos/status", "/todos/stats"]
  end

  def run
    index = 0

    loop do
      request(request_paths[index % request_paths.length])
      index += 1
      sleep_interval
    end
  end

  private

  def request(path)
    uri = URI.join(@base_url, path)
    Net::HTTP.get_response(uri)
  end

  def sleep_interval
    sleep(1.0 / @rate)
  end
end

if $PROGRAM_NAME == __FILE__
  Harness.new(base_url: ENV.fetch("BASE_URL", "http://localhost:3000")).run
end
