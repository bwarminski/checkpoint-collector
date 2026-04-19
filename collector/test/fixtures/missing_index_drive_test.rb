# ABOUTME: Verifies the missing-index fixture drive waits for readiness and records the traffic window.
# ABOUTME: Covers concurrent request dispatch and the last-run metadata file used by later assertions.
require "json"
require "minitest/autorun"
require "socket"
require "tmpdir"
require_relative "../../../fixtures/missing-index/load/drive"
require_relative "../../lib/fixtures/manifest"

class MissingIndexDriveTest < Minitest::Test
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
end
