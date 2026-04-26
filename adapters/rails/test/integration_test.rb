# ABOUTME: Verifies the Rails adapter lifecycle against fixture and real demo apps.
# ABOUTME: Keeps integration coverage opt-in so local unit runs stay fast.
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "uri"
require "bundler"
require "timeout"
require_relative "test_helper"

class IntegrationTest < Minitest::Test
  def test_fixture_adapter_env_removes_inherited_postgres_urls
    with_env(
      "RUN_RAILS_INTEGRATION" => "1",
      "DATABASE_URL" => "postgres://postgres:postgres@localhost:5432/checkpoint_demo",
      "BENCH_ADAPTER_PG_ADMIN_URL" => "postgres://postgres:postgres@localhost:5432/postgres",
    ) do
      env = adapter_env

      assert env.key?("DATABASE_URL"), "fixture adapter env must explicitly unset DATABASE_URL"
      assert env.key?("BENCH_ADAPTER_PG_ADMIN_URL"), "fixture adapter env must explicitly unset BENCH_ADAPTER_PG_ADMIN_URL"
      assert_nil env["DATABASE_URL"]
      assert_nil env["BENCH_ADAPTER_PG_ADMIN_URL"]
    end
  end

  def test_prepare_migrate_load_start_and_stop_against_fixture_app
    skip "set RUN_RAILS_INTEGRATION=1 to run" unless ENV["RUN_RAILS_INTEGRATION"] == "1"

    app_root = File.expand_path("fixtures/demo_app", __dir__)
    install_bundle(app_root)
    adapter = bench_adapter_bin

    assert_command_ok(adapter, "prepare", "--app-root", app_root)
    assert_command_ok(adapter, "migrate", "--app-root", app_root)
    assert_command_ok(adapter, "load-dataset", "--app-root", app_root, "--workload", "demo", "--seed", "7", "--env", "ROWS_PER_TABLE=10", "--env", "OPEN_FRACTION=0.2")
    start = assert_command_ok(adapter, "start", "--app-root", app_root)
    assert_equal "200", wait_for_up(start.fetch("base_url")).code
    assert_command_ok(adapter, "stop", "--pid", start.fetch("pid").to_s)
  end

  def test_real_db_specialist_demo_end_to_end
    skip "set RUN_DB_SPECIALIST_DEMO_INTEGRATION=1 and DB_SPECIALIST_DEMO_PATH" unless ENV["RUN_DB_SPECIALIST_DEMO_INTEGRATION"] == "1" && ENV["DB_SPECIALIST_DEMO_PATH"]

    app_root = ENV.fetch("DB_SPECIALIST_DEMO_PATH")
    adapter = bench_adapter_bin

    assert_command_ok(adapter, "prepare", "--app-root", app_root)
    assert_command_ok(adapter, "reset-state", "--app-root", app_root, "--seed", "42", "--env", "ROWS_PER_TABLE=1000", "--env", "OPEN_FRACTION=0.002")
    start = assert_command_ok(adapter, "start", "--app-root", app_root)
    assert_equal "200", wait_for_up(start.fetch("base_url")).code
    assert_command_ok(adapter, "stop", "--pid", start.fetch("pid").to_s)
  end

  private

  def assert_command_ok(adapter, *argv)
    stdout, stderr, status = Open3.capture3(adapter_env, RbConfig.ruby, adapter, "--json", *argv)
    assert status.success?, "stderr: #{stderr}\nstdout: #{stdout}"
    payload = JSON.parse(stdout)
    assert payload.fetch("ok"), payload.inspect
    payload
  end

  def bench_adapter_bin
    File.expand_path("../bin/bench-adapter", __dir__)
  end

  def install_bundle(app_root)
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(bundle_env(app_root), "bundle", "install", chdir: app_root)
    end
    assert status.success?, "stderr: #{stderr}\nstdout: #{stdout}"
  end

  def adapter_env
    return {} unless ENV["RUN_RAILS_INTEGRATION"] == "1"

    fixture_env(File.expand_path("fixtures/demo_app", __dir__))
  end

  def bundle_env(app_root)
    {
      "BUNDLE_GEMFILE" => File.join(app_root, "Gemfile"),
      "BUNDLE_PATH" => File.join(app_root, "vendor/bundle"),
      "BUNDLE_USER_HOME" => File.join(app_root, ".bundle-home"),
    }
  end

  def fixture_env(app_root)
    bundle_env(app_root).merge(
      "DATABASE_URL" => nil,
      "BENCH_ADAPTER_PG_ADMIN_URL" => nil,
    )
  end

  def with_env(overrides)
    previous = overrides.transform_values { nil }
    overrides.each_key { |key| previous[key] = ENV[key] }
    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def wait_for_up(base_url)
    uri = URI("#{base_url}/up")
    Timeout.timeout(10) do
      loop do
        response = Net::HTTP.get_response(uri)
        return response if response.code == "200"

        sleep 0.2
      rescue Errno::ECONNREFUSED
        sleep 0.2
      end
    end
  end
end
