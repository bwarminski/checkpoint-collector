# ABOUTME: Verifies the mixed missing-index fixture still exposes its intended pathologies.
# ABOUTME: Checks the bad status scan, counts N+1 query fan-out, and search explain shape.
require "json"
require "pg"

module Load
  class FixtureVerifier
    VerificationError = Class.new(StandardError)

    INDEX_SCAN_NODE_TYPES = ["Index Scan", "Index Only Scan", "Bitmap Index Scan"].freeze
    COUNTS_PATH = "/api/todos/counts".freeze
    MISSING_INDEX_PATH = "/api/todos?status=open".freeze
    SEARCH_PATH = "/api/todos/search?q=foo".freeze
    MISSING_INDEX_SQL = "EXPLAIN (FORMAT JSON) SELECT * FROM todos WHERE status = 'open'".freeze
    SEARCH_SQL = "EXPLAIN (FORMAT JSON) SELECT * FROM todos WHERE title LIKE '%foo%' ORDER BY created_at DESC LIMIT 50".freeze
    COUNTS_CALLS_SQL = <<~SQL.freeze
      SELECT COALESCE(SUM(calls), 0)::bigint AS calls
      FROM pg_stat_statements
      WHERE query LIKE '%FROM "todos"%'
        AND query LIKE '%COUNT(%'
        AND query LIKE '%"todos"."user_id"%'
    SQL

    def initialize(workload_name:, adapter_bin: nil, app_root: nil, stdout: $stdout, stderr: $stderr, client_factory: nil, explain_reader: nil, stats_reset: nil, counts_calls_reader: nil, search_reference_reader: nil, database_url: ENV["DATABASE_URL"], pg: PG)
      @workload_name = workload_name
      @adapter_bin = adapter_bin
      @app_root = app_root
      @stdout = stdout
      @stderr = stderr
      @client_factory = client_factory || ->(base_url) { Load::Client.new(base_url:) }
      @explain_reader = explain_reader || build_explain_reader(database_url:, pg:)
      @stats_reset = stats_reset || build_stats_reset(database_url:, pg:)
      @counts_calls_reader = counts_calls_reader || build_counts_calls_reader(database_url:, pg:)
      @search_reference_reader = search_reference_reader || -> { JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan") }
    end

    def call(base_url:)
      raise ArgumentError, "unknown workload: #{@workload_name}" unless @workload_name == "missing-index-todos"

      {
        ok: true,
        checks: [
          verify_missing_index,
          verify_counts_n_plus_one(base_url:),
          verify_search_rewrite,
        ],
      }
    end

    private

    def verify_missing_index
      plan = @explain_reader.call(MISSING_INDEX_SQL)
      todos_nodes = relation_nodes(plan, "todos")
      rejected_node = todos_nodes.find { |node| INDEX_SCAN_NODE_TYPES.include?(node.fetch("Node Type")) }
      raise VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected Seq Scan on todos, saw #{rejected_node.fetch("Node Type")}" if rejected_node

      seq_scan = todos_nodes.find do |node|
        node.fetch("Node Type") == "Seq Scan" && node.fetch("Filter", "").include?("status")
      end
      raise VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected Seq Scan on todos with a status filter" unless seq_scan

      { name: "missing_index", ok: true, node_type: seq_scan.fetch("Node Type") }
    end

    def verify_counts_n_plus_one(base_url:)
      @stats_reset.call
      response = @client_factory.call(base_url).get(COUNTS_PATH)
      ensure_success!(response, COUNTS_PATH)
      users_count = JSON.parse(response.body.to_s).length

      calls = @counts_calls_reader.call.to_i
      if calls < users_count
        raise VerificationError, "fixture verification failed for #{COUNTS_PATH}: expected at least #{users_count} count calls for #{users_count} users, saw #{calls}"
      end

      { name: "counts_n_plus_one", ok: true, calls:, users: users_count }
    end

    def verify_search_rewrite
      plan = @explain_reader.call(SEARCH_SQL)
      reference_plan = @search_reference_reader.call
      unless plan_matches_reference?(actual: plan, reference: reference_plan)
        raise VerificationError, "fixture verification failed for #{SEARCH_PATH}: search explain tree drifted from fixtures/mixed-todo-app/search-explain.json"
      end

      { name: "search_rewrite", ok: true, node_type: plan.fetch("Node Type") }
    end

    def ensure_success!(response, path)
      code = response.code.to_i
      return if code >= 200 && code < 300

      raise VerificationError, "fixture verification failed for #{path}: expected 2xx response, saw #{response.code}"
    end

    def relation_nodes(node, relation_name)
      matches = []
      matches << node if node["Relation Name"] == relation_name
      Array(node["Plans"]).each do |child|
        matches.concat(relation_nodes(child, relation_name))
      end
      matches
    end

    def plan_matches_reference?(actual:, reference:)
      reference.all? do |key, value|
        actual.key?(key) && values_match_reference?(actual.fetch(key), value)
      end
    end

    def values_match_reference?(actual, reference)
      case reference
      when Hash
        actual.is_a?(Hash) && plan_matches_reference?(actual:, reference:)
      when Array
        actual.is_a?(Array) &&
          actual.length >= reference.length &&
          reference.each_with_index.all? do |child_reference, index|
            values_match_reference?(actual.fetch(index), child_reference)
          end
      else
        actual == reference
      end
    end

    def build_explain_reader(database_url:, pg:)
      ensure_database_url!(database_url)
      lambda do |sql|
        with_connection(database_url:, pg:) do |connection|
          rows = connection.exec(sql)
          JSON.parse(rows.first.fetch("QUERY PLAN")).fetch(0).fetch("Plan")
        end
      end
    end

    def build_stats_reset(database_url:, pg:)
      ensure_database_url!(database_url)
      lambda do
        with_connection(database_url:, pg:) do |connection|
          connection.exec("SELECT pg_stat_statements_reset()")
        end
      end
    end

    def build_counts_calls_reader(database_url:, pg:)
      ensure_database_url!(database_url)
      lambda do
        with_connection(database_url:, pg:) do |connection|
          connection.exec(COUNTS_CALLS_SQL).first.fetch("calls")
        end
      end
    end

    def with_connection(database_url:, pg:)
      connection = pg.connect(database_url)
      yield connection
    ensure
      connection&.close
    end

    def ensure_database_url!(database_url)
      return database_url unless database_url.nil? || database_url.empty?

      raise ArgumentError, "missing DATABASE_URL for fixture verification"
    end

    def search_reference_path
      File.expand_path("../../../fixtures/mixed-todo-app/search-explain.json", __dir__)
    end
  end
end
