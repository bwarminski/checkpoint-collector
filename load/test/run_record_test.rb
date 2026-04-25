# ABOUTME: Verifies run record files are created and appended as JSON.
# ABOUTME: Covers the minimal on-disk artifact behavior for runner bookkeeping.
require "json"
require "tmpdir"
require_relative "test_helper"

class RunRecordTest < Minitest::Test
  def test_write_run_overwrites_run_json
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)

      run_record.write_run(id: "abc123", workload: "missing-index-todos")

      payload = JSON.parse(File.read(File.join(dir, "run.json")))
      assert_equal "abc123", payload.fetch("id")
      assert_equal "missing-index-todos", payload.fetch("workload")
    end
  end

  def test_append_metrics_and_adapter_commands_write_jsonl
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)

      run_record.append_metrics(actions: { a: { count: 2 } })
      run_record.append_adapter_command(command: "reset-state", ok: true)

      metrics_lines = File.read(File.join(dir, "metrics.jsonl")).lines
      adapter_lines = File.read(File.join(dir, "adapter-commands.jsonl")).lines

      assert_equal 1, metrics_lines.length
      assert_equal 1, adapter_lines.length
      assert_equal 2, JSON.parse(metrics_lines.first).fetch("actions").fetch("a").fetch("count")
      assert_equal true, JSON.parse(adapter_lines.first).fetch("ok")
    end
  end

  def test_read_run_json_returns_persisted_warnings
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)

      run_record.write_run(
        run_id: "abc123",
        warnings: [
          {
            type: "invariant_breach",
            message: "open_count 100 is below open_floor 30000",
          },
        ],
      )

      payload = run_record.read_run_json

      assert_equal "abc123", payload.fetch("run_id")
      assert_equal "invariant_breach", payload.fetch("warnings").first.fetch("type")
    end
  end

  def test_write_run_never_exposes_partial_json_to_concurrent_readers
    Dir.mktmpdir do |dir|
      run_record = Load::RunRecord.new(run_dir: dir)
      errors = Queue.new
      stop = false
      reader = Thread.new do
        until stop
          begin
            contents = File.read(File.join(dir, "run.json"))
            JSON.parse(contents) unless contents.empty?
          rescue Errno::ENOENT
          rescue JSON::ParserError => error
            errors << error
            break
          end
        end
      end

      payload = { "data" => "x" * 5_000_000 }
      50.times do |index|
        payload["index"] = index
        run_record.write_run(payload)
      end

      stop = true
      reader.join

      assert errors.empty?, "expected concurrent readers to see only complete JSON"
    end
  end
end
