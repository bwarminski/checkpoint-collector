# ABOUTME: Issues HTTP requests against the application under test.
# ABOUTME: Wraps Net::HTTP with a base URL and simple request helpers.
require "net/http"
require "uri"

module Load
  class Client
    def initialize(base_url:, http: Net::HTTP)
      @base_url = URI(base_url)
      @http = http
    end

    def get(path)
      request(:get, path)
    end

    def request(method, path)
      uri = uri_for(path)

      @http.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request_class = Net::HTTP.const_get(method.to_s.capitalize)
        http.request(request_class.new(uri))
      end
    end

    private

    def uri_for(path)
      URI.join(@base_url.to_s.end_with?("/") ? @base_url.to_s : "#{@base_url}/", path.sub(/\A\//, ""))
    end
  end
end
