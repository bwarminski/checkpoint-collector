# ABOUTME: Issues HTTP requests against the application under test.
# ABOUTME: Wraps Net::HTTP with a base URL and simple request helpers.
require "net/http"
require "uri"

module Load
  class Client
    HTTP_TIMEOUT_SECONDS = 5

    class Connection
      def initialize(http)
        @http = http
      end

      def start
        self
      end

      def request(request)
        @http.request(request)
      end

      def finish
      end
    end

    def initialize(base_url:, http: Net::HTTP)
      @base_url = URI(base_url)
      @http = http
      @connection = nil
    end

    def get(path)
      request(:get, path)
    end

    def start
      return self if @connection

      @connection = build_connection
      @connection.start
      self
    end

    def finish
      return unless @connection

      @connection.finish
      @connection = nil
    end

    def request(method, path)
      uri = uri_for(path)
      request_class = Net::HTTP.const_get(method.to_s.capitalize)
      request = request_class.new(uri)

      if @connection
        @connection.request(request)
      elsif @http.respond_to?(:new)
        connection = build_connection
        begin
          connection.start
          connection.request(request)
        ensure
          connection&.finish
        end
      else
        @http.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          configure_timeouts(http)
          http.request(request)
        end
      end
    end

    private

    def uri_for(path)
      URI.join(@base_url.to_s.end_with?("/") ? @base_url.to_s : "#{@base_url}/", path.sub(/\A\//, ""))
    end

    def configure_timeouts(http)
      http.open_timeout = HTTP_TIMEOUT_SECONDS if http.respond_to?(:open_timeout=)
      http.read_timeout = HTTP_TIMEOUT_SECONDS if http.respond_to?(:read_timeout=)
      http.write_timeout = HTTP_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30 if http.respond_to?(:keep_alive_timeout=)
    end

    def build_connection
      return Connection.new(@http) unless @http.respond_to?(:new)

      connection = @http.new(@base_url.host, @base_url.port)
      connection.use_ssl = @base_url.scheme == "https" if connection.respond_to?(:use_ssl=)
      configure_timeouts(connection)
      connection
    end
  end
end
