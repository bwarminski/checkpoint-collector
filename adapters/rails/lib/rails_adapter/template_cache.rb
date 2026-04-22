# ABOUTME: Manages the adapter-private Postgres template database for fast resets.
# ABOUTME: Uses an admin connection to create, clone, and drop the cached template.
require "digest"
require "uri"

module RailsAdapter
  class TemplateCache
    IDENTIFIER_LIMIT = 63
    TEMPLATE_SUFFIX_LENGTH = "_tmpl_".length + 12

    def initialize(pg: nil, admin_url: ENV["BENCH_ADAPTER_PG_ADMIN_URL"] || ENV["DATABASE_URL"])
      @pg = pg
      @admin_url = admin_url
    end

    def template_exists?(database_name:, app_root:, **)
      with_connection do |connection|
        connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [template_name(database_name, app_root:)]).ntuples.positive?
      end
    end

    def build_template(database_name:, app_root:, **)
      with_connection do |connection|
        connection.exec("CREATE DATABASE #{template_name(database_name, app_root:)} TEMPLATE #{database_name}")
      end
    end

    def clone_template(database_name:, app_root:, **)
      with_connection do |connection|
        connection.exec_params(<<~SQL, [database_name])
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()
        SQL
        connection.exec("DROP DATABASE IF EXISTS #{database_name}")
        connection.exec("CREATE DATABASE #{database_name} TEMPLATE #{template_name(database_name, app_root:)}")
      end
    end

    private

    def with_connection
      raise "BENCH_ADAPTER_PG_ADMIN_URL or DATABASE_URL is required" unless @admin_url

      uri = URI.parse(@admin_url)
      uri.path = "/postgres"
      connection = pg_driver.connect(uri.to_s)
      yield connection
    ensure
      connection&.close
    end

    def pg_driver
      return @pg if @pg

      require "pg"
      PG
    end

    def template_name(database_name, app_root:)
      digest = schema_digest(app_root)
      max_prefix_length = IDENTIFIER_LIMIT - TEMPLATE_SUFFIX_LENGTH
      prefix = database_name[0, max_prefix_length]
      "#{prefix}_tmpl_#{digest}"
    end

    def schema_digest(app_root)
      schema_path = if File.exist?(File.join(app_root, "db", "structure.sql"))
        File.join(app_root, "db", "structure.sql")
      else
        File.join(app_root, "db", "schema.rb")
      end

      Digest::SHA256.file(schema_path).hexdigest[0, 12]
    end
  end
end
