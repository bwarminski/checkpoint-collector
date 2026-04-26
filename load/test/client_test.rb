# ABOUTME: Verifies the HTTP client reuses one connection for repeated requests.
# ABOUTME: Covers explicit connection start and finish lifecycle behavior.
require_relative "test_helper"

class ClientTest < Minitest::Test
  FakeResponse = Struct.new(:code)

  class FakeConnection
    attr_reader :requests
    attr_accessor :open_timeout, :read_timeout, :write_timeout, :keep_alive_timeout, :use_ssl

    def initialize
      @requests = []
      @started = false
      @finished = false
    end

    def start
      @started = true
      self
    end

    def request(request)
      @requests << request
      FakeResponse.new("200")
    end

    def finish
      raise IOError, "HTTP session not yet started" unless @started

      @finished = true
    end

    def started?
      @started
    end

    def finished?
      @finished
    end
  end

  class FakeHttp
    attr_reader :calls

    def initialize(connection)
      @connection = connection
      @calls = []
    end

    def new(host, port)
      @calls << [host, port]
      @connection
    end
  end

  def test_client_reuses_one_connection_across_requests
    connection = FakeConnection.new
    http = FakeHttp.new(connection)
    client = Load::Client.new(base_url: "http://example.test:3000", http:)

    client.start
    client.get("/one")
    client.get("/two")
    client.finish

    assert_equal [["example.test", 3000]], http.calls
    assert connection.started?
    assert connection.finished?
    assert_equal 2, connection.requests.length
    assert_equal "/one", connection.requests.first.path
    assert_equal "/two", connection.requests.last.path
  end

  def test_client_accepts_custom_http_timeout
    connection = FakeConnection.new
    http = FakeHttp.new(connection)
    client = Load::Client.new(base_url: "http://example.test:3000", http:, timeout_seconds: 17)

    client.start

    assert_equal 17, connection.open_timeout
    assert_equal 17, connection.read_timeout
    assert_equal 17, connection.write_timeout
    assert_equal 30, connection.keep_alive_timeout
  end

  def test_finish_is_safe_after_start_raises_before_session_begins
    connection = FakeConnection.new
    connection.define_singleton_method(:start) do
      raise IOError, "boom"
    end
    http = FakeHttp.new(connection)
    client = Load::Client.new(base_url: "http://example.test:3000", http:)

    assert_raises(IOError) { client.start }

    client.finish
  end

  def test_start_uses_started_session_when_connection_returns_one
    session = FakeConnection.new
    connection = Object.new
    connection.define_singleton_method(:open_timeout=) { |_| }
    connection.define_singleton_method(:read_timeout=) { |_| }
    connection.define_singleton_method(:write_timeout=) { |_| }
    connection.define_singleton_method(:keep_alive_timeout=) { |_| }
    connection.define_singleton_method(:start) { session.start }
    http = FakeHttp.new(connection)
    client = Load::Client.new(base_url: "http://example.test:3000", http:)

    client.start
    client.get("/one")
    client.finish

    assert_equal 1, session.requests.length
    assert session.finished?
  end

  def test_one_shot_request_uses_started_session_when_connection_returns_one
    session = FakeConnection.new
    connection = Object.new
    connection.define_singleton_method(:open_timeout=) { |_| }
    connection.define_singleton_method(:read_timeout=) { |_| }
    connection.define_singleton_method(:write_timeout=) { |_| }
    connection.define_singleton_method(:keep_alive_timeout=) { |_| }
    connection.define_singleton_method(:start) { session.start }
    http = FakeHttp.new(connection)
    client = Load::Client.new(base_url: "http://example.test:3000", http:)

    client.get("/one")

    assert_equal 1, session.requests.length
    assert session.finished?
  end

  def test_request_encodes_body_for_delete_requests
    connection = FakeConnection.new
    http = FakeHttp.new(connection)
    client = Load::Client.new(base_url: "http://example.test:3000", http:)

    client.request(:delete, "/api/todos/completed", body: { user_id: 7 })

    request = connection.requests.first
    assert_instance_of Net::HTTP::Delete, request
    assert_equal "/api/todos/completed", request.path
    assert_equal "{\"user_id\":7}", request.body
    assert_equal "application/json", request["Content-Type"]
  end
end
