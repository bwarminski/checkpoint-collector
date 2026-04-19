# ABOUTME: Verifies the missing-index fixture drive waits for readiness and records the traffic window.
# ABOUTME: Covers concurrent request dispatch and the last-run metadata file used by later assertions.
require "json"
require "minitest/autorun"
require "socket"
require "tmpdir"
require_relative "../../../fixtures/missing-index/load/drive"
require_relative "../../lib/fixtures/manifest"

class MissingIndexDriveTest < Minitest::Test
  def test_uses_one_limiter_before_requests_across_workers
    fake_clock = FakeClock.new(Time.utc(2026, 4, 19, 0, 0, 0))
    events = []
    limiter = RecordingLimiter.new(events)
    limiter_new_calls = 0
    manifest = Fixtures::Manifest.load("missing-index")

    with_rate_limiter_stub(limiter, -> { limiter_new_calls += 1 }) do
      Class.new(Fixtures::MissingIndex::Drive) do
        define_method(:healthy?) do
          true
        end

        define_method(:request_endpoint) do
          events << :request
          fake_clock.advance_by(1)
        end
      end.new(
        manifest: manifest,
        options: { base_url: "http://127.0.0.1:1", seconds: 1, concurrency: 2, rate: 1, output_dir: Dir.mktmpdir },
        clock: -> { fake_clock.now },
        sleeper: ->(seconds) { fake_clock.advance_by(seconds) },
      ).run
    end

    assert_equal 1, limiter_new_calls
    assert_equal :wait, events.first
    assert_includes events, :request
  end

  def test_raises_when_a_worker_request_fails
    fake_clock = FakeClock.new(Time.utc(2026, 4, 19, 0, 0, 0))
    manifest = Fixtures::Manifest.load("missing-index")
    drive = Class.new(Fixtures::MissingIndex::Drive) do
      def healthy?
        true
      end

      def request_endpoint
        raise "boom"
      end
    end.new(
      manifest: manifest,
      options: { base_url: "http://127.0.0.1:1", seconds: 1, concurrency: 2, rate: "unlimited", output_dir: Dir.mktmpdir },
      clock: -> { fake_clock.now },
      sleeper: ->(seconds) { fake_clock.advance_by(seconds) },
    )

    error = assert_raises(RuntimeError) { drive.run }

    assert_equal "boom", error.message
  end

  def test_waits_for_up_endpoint_then_records_last_run_window
    requests = Queue.new
    health_checks = 0
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        next unless request_line

        path = request_line.split(" ")[1]
        while (line = client.gets)
          break if line == "\r\n"
        end

        status, body =
          case path
          when "/up"
            health_checks += 1
            [health_checks < 3 ? 503 : 200, "ok"]
          when "/todos/status?status=open"
            requests << "open"
            [200, "ok"]
          else
            [404, "not found"]
          end

        client.write("HTTP/1.1 #{status} OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      ensure
        client&.close
      end
    end

    manifest = Fixtures::Manifest.load("missing-index")
    Dir.mktmpdir do |dir|
      Fixtures::MissingIndex::Drive.new(
        manifest: manifest,
        options: {
          base_url: "http://127.0.0.1:#{port}",
          seconds: 1,
          concurrency: 2,
          rate: "unlimited",
          output_dir: dir,
        },
      ).run

      payload = JSON.parse(File.read(File.join(dir, "fixture-last-run.json")))
      assert_operator payload.fetch("request_count"), :>, 0
      assert payload.fetch("start_ts") <= payload.fetch("end_ts")
      assert_equal "open", requests.pop
    end
  ensure
    server&.close
    thread&.join
  end

  def test_timeout_reports_last_health_probe_status
    fake_clock = FakeClock.new(Time.utc(2026, 4, 19, 0, 0, 0))
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        next unless request_line

        while (line = client.gets)
          break if line == "\r\n"
        end

        body = "not ready"
        client.write("HTTP/1.1 404 Not Found\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      ensure
        client&.close
      end
    end

    manifest = Fixtures::Manifest.load("missing-index")
    drive = Fixtures::MissingIndex::Drive.new(
      manifest: manifest,
      options: {
        base_url: "http://127.0.0.1:#{port}",
        seconds: 1,
        concurrency: 1,
        rate: "unlimited",
        output_dir: Dir.mktmpdir,
      },
      clock: -> { fake_clock.now },
      sleeper: ->(seconds) { fake_clock.advance_by(seconds) },
    )

    error = assert_raises(RuntimeError) { drive.run }

    assert_includes error.message, "Timed out waiting for"
    assert_includes error.message, "last status: 404"
  ensure
    server&.close
    thread&.join
  end

  private

  def with_rate_limiter_stub(limiter, counter)
    original_new = Fixtures::MissingIndex::Drive::RateLimiter.method(:new)
    Fixtures::MissingIndex::Drive::RateLimiter.define_singleton_method(:new) do |*args, **kwargs|
      counter.call
      limiter
    end
    yield
  ensure
    Fixtures::MissingIndex::Drive::RateLimiter.define_singleton_method(:new, original_new)
  end

  class RecordingLimiter
    def initialize(events)
      @events = events
    end

    def wait_turn
      @events << :wait
    end
  end

  class FakeClock
    def initialize(current_time)
      @current_time = current_time
    end

    def now
      @current_time
    end

    def advance_by(seconds)
      @current_time += seconds
    end
  end
end
