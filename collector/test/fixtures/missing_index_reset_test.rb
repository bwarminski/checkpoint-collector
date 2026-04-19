# ABOUTME: Verifies the missing-index fixture reset rebuilds the template and working database.
# ABOUTME: Covers the schema file shape and the pg_stat_statements reset call used by the reset path.
require "minitest/autorun"
require_relative "../../../fixtures/missing-index/setup/reset"
require_relative "../../lib/fixtures/manifest"

class MissingIndexResetTest < Minitest::Test
  def test_rebuild_template_drops_existing_template_and_working_database
    statements = []
    manifest = Fixtures::Manifest.load("missing-index")

    Fixtures::MissingIndex::Reset.new(
      manifest: manifest,
      options: { admin_url: "postgresql://localhost/postgres", rebuild_template: true },
      pg: FakePg.new(
        admin: FakeConnection.new(statements, exists: false),
        template: FakeConnection.new(statements, exists: false),
      ),
    ).run

    assert_includes statements, 'DROP DATABASE IF EXISTS "fixture_01"'
    assert_includes statements, 'DROP DATABASE IF EXISTS "fixture_01_tmpl"'
    assert_includes statements, 'CREATE DATABASE "fixture_01_tmpl"'
    assert_includes statements, 'CREATE DATABASE "fixture_01" TEMPLATE "fixture_01_tmpl"'
    assert_includes statements, "SELECT pg_stat_statements_reset()"
  end

  def test_template_exists_skips_build
    statements = []
    manifest = Fixtures::Manifest.load("missing-index")

    Fixtures::MissingIndex::Reset.new(
      manifest: manifest,
      options: { admin_url: "postgresql://localhost/postgres", rebuild_template: false },
      pg: FakePg.new(
        admin: FakeConnection.new(statements, exists: true),
        template: FakeConnection.new(statements, exists: true),
      ),
    ).run

    refute_includes statements, 'CREATE DATABASE "fixture_01_tmpl"'
    assert_includes statements, 'CREATE DATABASE "fixture_01" TEMPLATE "fixture_01_tmpl"'
  end

  def test_template_build_failure_drops_poisoned_template
    statements = []
    manifest = Fixtures::Manifest.load("missing-index")
    pg = FakePg.new(
      admin: FakeConnection.new(statements, exists: false),
      template: FailingTemplateConnection.new(statements, exists: false),
    )

    error = assert_raises(RuntimeError) do
      Fixtures::MissingIndex::Reset.new(
        manifest: manifest,
        options: { admin_url: "postgresql://localhost/postgres", rebuild_template: false },
        pg: pg,
      ).run
    end

    assert_equal "seed failed", error.message
    assert_includes statements, 'CREATE DATABASE "fixture_01_tmpl"'
    assert_includes statements, 'DROP DATABASE IF EXISTS "fixture_01_tmpl"'
    refute_includes statements, 'CREATE DATABASE "fixture_01" TEMPLATE "fixture_01_tmpl"'
  end

  def test_schema_file_creates_user_id_index_and_no_status_index
    sql = File.read(File.expand_path("../../../fixtures/missing-index/setup/01_schema.sql", __dir__))

    assert_includes sql, "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
    assert_includes sql, "CREATE INDEX index_todos_on_user_id"
    refute_match(/CREATE INDEX .*status/i, sql)
    refute_includes sql, "index_todos_on_status"
  end

  # Returns the same connection for every connect() call so load_sql's additional
  # connects don't exhaust a finite pool.
  class FakePg
    def initialize(admin:, template:)
      @admin = admin
      @template = template
    end

    def connect(url)
      url.include?("/fixture_01_tmpl") ? @template : @admin
    end
  end

  FakeResult = Struct.new(:ntuples)

  class FakeConnection
    def initialize(statements, exists:)
      @statements = statements
      @exists = exists
    end

    def exec(sql)
      @statements << sql.strip
      []
    end

    # Used by database_exists? — returns ntuples=1 (exists) or ntuples=0 (absent).
    def exec_params(sql, _params)
      @statements << sql.strip
      FakeResult.new(@exists ? 1 : 0)
    end

    def close; end
  end

  class FailingTemplateConnection < FakeConnection
    def exec(sql)
      super
      raise "seed failed" if sql.include?("INSERT INTO todos")

      []
    end
  end
end
