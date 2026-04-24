# ABOUTME: Verifies the Rails template cache keys template names by app schema.
# ABOUTME: Prevents stale template reuse when the benchmark app changes schema.
require "digest"
require "fileutils"
require_relative "test_helper"

class TemplateCacheTest < Minitest::Test
  def test_build_template_uses_schema_and_seed_specific_template_name
    first_connection = RecordingConnection.new
    second_connection = RecordingConnection.new
    cache = RailsAdapter::TemplateCache.new(pg: FakePgDriver.new([first_connection, second_connection]), admin_url: "postgres://postgres:postgres@localhost:5432/checkpoint_demo")

    app_root = build_app_root(schema: "create_table :todos do |t|\nend\n")

    cache.build_template(database_name: "checkpoint_demo", app_root:, env_pairs: { "ROWS_PER_TABLE" => "1000", "OPEN_FRACTION" => "0.2", "SEED" => "7" })
    cache.build_template(database_name: "checkpoint_demo", app_root:, env_pairs: { "ROWS_PER_TABLE" => "10000000", "OPEN_FRACTION" => "0.002", "SEED" => "42" })

    refute_equal first_connection.exec_calls.first, second_connection.exec_calls.first
    assert_match(/CREATE DATABASE checkpoint_demo_tmpl_[0-9a-f]{12}_[0-9a-f]{8} TEMPLATE checkpoint_demo/, first_connection.exec_calls.first)
    assert_match(/CREATE DATABASE checkpoint_demo_tmpl_[0-9a-f]{12}_[0-9a-f]{8} TEMPLATE checkpoint_demo/, second_connection.exec_calls.first)
  end

  def test_template_exists_queries_schema_and_seed_specific_template_name
    connection = RecordingConnection.new
    cache = RailsAdapter::TemplateCache.new(pg: FakePgDriver.new([connection]), admin_url: "postgres://postgres:postgres@localhost:5432/checkpoint_demo")
    schema = "create_table :todos do |t|\nend\n"
    app_root = build_app_root(schema:)

    seed_env = { "ROWS_PER_TABLE" => "1000", "OPEN_FRACTION" => "0.2", "SEED" => "7" }
    cache.template_exists?(database_name: "checkpoint_demo", app_root:, env_pairs: seed_env)

    seed_digest = Digest::SHA256.hexdigest(seed_env.sort.to_a.to_s)[0, 8]
    assert_equal ["checkpoint_demo_tmpl_#{Digest::SHA256.hexdigest(schema)[0, 12]}_#{seed_digest}"], connection.exec_params_calls.first.fetch(:params)
  end

  def test_template_cache_rejects_invalid_database_names
    cache = RailsAdapter::TemplateCache.new(pg: FakePgDriver.new([RecordingConnection.new]), admin_url: "postgres://postgres:postgres@localhost:5432/checkpoint_demo")
    app_root = build_app_root(schema: "create_table :todos do |t|\nend\n")

    error = assert_raises(ArgumentError) do
      cache.build_template(database_name: "bad-name;drop database postgres", app_root:, env_pairs: {})
    end

    assert_includes error.message, "invalid database name"
  end

  private

  def build_app_root(schema:)
    Dir.mktmpdir.tap do |root|
      db_dir = File.join(root, "db")
      FileUtils.mkdir_p(db_dir)
      File.write(File.join(db_dir, "schema.rb"), schema)
    end
  end

  class FakePgDriver
    def initialize(connections)
      @connections = connections
    end

    def connect(*)
      @connections.shift
    end
  end

  class RecordingConnection
    attr_reader :exec_calls, :exec_params_calls

    def initialize
      @exec_calls = []
      @exec_params_calls = []
    end

    def exec(sql)
      @exec_calls << sql
    end

    def exec_params(sql, params)
      @exec_params_calls << { sql:, params: }
      FakePgResult.new(0)
    end

    def close
    end
  end

  FakePgResult = Struct.new(:ntuples)
end
