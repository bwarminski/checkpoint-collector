# ABOUTME: Rebuilds the missing-index fixture database from SQL files and a Postgres template database.
# ABOUTME: Keeps reset fast by cloning `fixture_01` from `fixture_01_tmpl` after the first seed run.
require "pg"
require "uri"

module Fixtures
  module MissingIndex
    class Reset
      def initialize(manifest:, options:, pg: PG)
        @manifest = manifest
        @options = options
        @pg = pg
      end

      def run
        admin = @pg.connect(@options.fetch(:admin_url))
        rebuild_template(admin) if @options[:rebuild_template]
        ensure_template(admin)
        recreate_working_database(admin)
        reset_pg_stat_statements
      ensure
        admin&.close
      end

      private

      def ensure_template(admin)
        return if database_exists?(admin, template_name)

        create_database(admin, template_name)
        load_sql(template_url, "01_schema.sql")
        load_sql(template_url, "02_seed.sql")
      end

      def rebuild_template(admin)
        drop_database(admin, @manifest.db_name)
        drop_database(admin, template_name)
      end

      def recreate_working_database(admin)
        drop_database(admin, @manifest.db_name)
        admin.exec(%(CREATE DATABASE "#{@manifest.db_name}" TEMPLATE "#{template_name}"))
      end

      def reset_pg_stat_statements
        worker = @pg.connect(database_url(@manifest.db_name))
        worker.exec("SELECT pg_stat_statements_reset()")
      ensure
        worker&.close
      end

      def load_sql(url, name)
        connection = @pg.connect(url)
        connection.exec(File.read(File.expand_path(name, File.expand_path(__dir__))))
      ensure
        connection&.close
      end

      def create_database(admin, name)
        admin.exec(%(CREATE DATABASE "#{name}"))
      end

      def drop_database(admin, name)
        admin.exec_params(<<~SQL, [name])
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()
        SQL
        admin.exec(%(DROP DATABASE IF EXISTS "#{name}"))
      end

      def database_exists?(admin, name)
        result = admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name])
        result.ntuples == 1
      end

      def template_name
        "#{@manifest.db_name}_tmpl"
      end

      def template_url
        database_url(template_name)
      end

      def database_url(name)
        base = URI.parse(@options.fetch(:admin_url))
        base.path = "/#{name}"
        base.to_s
      end
    end
  end
end
