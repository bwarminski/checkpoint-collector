# ABOUTME: Manages the adapter-private Postgres template database for fast resets.
# ABOUTME: Uses an admin connection to create, clone, and drop the cached template.
require "digest"
require "pg"
require "uri"

module RailsAdapter
  class TemplateCache
    def initialize(pg: PG, admin_url: ENV["BENCH_ADAPTER_PG_ADMIN_URL"] || ENV["DATABASE_URL"])
      @pg = pg
      @admin_url = admin_url
    end

    def template_exists?(database_name:, **)
      with_connection do |connection|
        connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [template_name(database_name)]).ntuples.positive?
      end
    end

    def build_template(database_name:, **)
      with_connection do |connection|
        connection.exec("CREATE DATABASE #{template_name(database_name)} TEMPLATE #{database_name}")
      end
    end

    def clone_template(database_name:, **)
      with_connection do |connection|
        connection.exec_params(<<~SQL, [database_name])
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()
        SQL
        connection.exec("DROP DATABASE IF EXISTS #{database_name}")
        connection.exec("CREATE DATABASE #{database_name} TEMPLATE #{template_name(database_name)}")
      end
    end

    private

    def with_connection
      raise "BENCH_ADAPTER_PG_ADMIN_URL or DATABASE_URL is required" unless @admin_url

      uri = URI.parse(@admin_url)
      uri.path = "/postgres"
      connection = @pg.connect(uri.to_s)
      yield connection
    ensure
      connection&.close
    end

    def template_name(database_name)
      "#{database_name}_tmpl"
    end
  end
end
