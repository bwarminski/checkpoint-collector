# ABOUTME: Verifies fixture manifests load from disk and expose the values commands need.
# ABOUTME: Covers happy-path parsing and unknown-fixture errors before implementation exists.
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../../lib/fixtures/manifest"

class FixtureManifestTest < Minitest::Test
  def test_loads_missing_index_manifest
    Dir.mktmpdir do |dir|
      fixture_dir = File.join(dir, "missing-index")
      FileUtils.mkdir_p(fixture_dir)
      File.write(File.join(fixture_dir, "manifest.yml"), <<~YAML)
        name: missing-index
        description: Seq scan on todos.status when an index would flip the plan.
        db_name: fixture_01
        demo_app:
          health_endpoint: /up
        workload:
          method: GET
          path: /todos/status?status=open
          seconds: 60
          concurrency: 16
          rate: unlimited
        signals:
          explain:
            root_node_kind: Seq Scan
            root_node_relation: todos
            query: SELECT 1
          clickhouse:
            statement_contains: todos.status
            min_call_count: 500
      YAML

      manifest = Fixtures::Manifest.load("missing-index", root: dir)

      assert_equal "missing-index", manifest.name
      assert_equal "fixture_01", manifest.db_name
      assert_equal "/up", manifest.health_endpoint
      assert_equal "GET", manifest.request_method
      assert_equal "/todos/status?status=open", manifest.request_path
      assert_equal "Seq Scan", manifest.explain_root_node_kind
    end
  end

  def test_raises_for_unknown_fixture
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) { Fixtures::Manifest.load("nope", root: dir) }

      assert_includes error.message, "Unknown fixture"
    end
  end
end
