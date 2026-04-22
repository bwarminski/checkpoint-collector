# ABOUTME: Verifies the Rails template cache keys template names by app schema.
# ABOUTME: Prevents stale template reuse when the benchmark app changes schema.
require "digest"
require "fileutils"
require_relative "test_helper"

class TemplateCacheTest < Minitest::Test
  def test_build_template_uses_schema_specific_template_name
    first_connection = RecordingConnection.new
    second_connection = RecordingConnection.new
    cache = RailsAdapter::TemplateCache.new(pg: FakePgDriver.new([first_connection, second_connection]), admin_url: "postgres://postgres:postgres@localhost:5432/checkpoint_demo")

    first_root = build_app_root(schema: "create_table :todos do |t|\nend\n")
    second_root = build_app_root(schema: "create_table :todos do |t|\n  t.index [:status]\nend\n")

    cache.build_template(database_name: "checkpoint_demo", app_root: first_root)
    cache.build_template(database_name: "checkpoint_demo", app_root: second_root)

    refute_equal first_connection.exec_calls.first, second_connection.exec_calls.first
    assert_match(/CREATE DATABASE checkpoint_demo_tmpl_[0-9a-f]{12} TEMPLATE checkpoint_demo/, first_connection.exec_calls.first)
    assert_match(/CREATE DATABASE checkpoint_demo_tmpl_[0-9a-f]{12} TEMPLATE checkpoint_demo/, second_connection.exec_calls.first)
  end

  def test_template_exists_queries_schema_specific_template_name
    connection = RecordingConnection.new
    cache = RailsAdapter::TemplateCache.new(pg: FakePgDriver.new([connection]), admin_url: "postgres://postgres:postgres@localhost:5432/checkpoint_demo")
    schema = "create_table :todos do |t|\nend\n"
    app_root = build_app_root(schema:)

    cache.template_exists?(database_name: "checkpoint_demo", app_root:)

    assert_equal ["checkpoint_demo_tmpl_#{Digest::SHA256.hexdigest(schema)[0, 12]}"], connection.exec_params_calls.first.fetch(:params)
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
