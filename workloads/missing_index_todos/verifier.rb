# ABOUTME: Verifies the missing-index workload fixture still exposes its intended pathologies.
# ABOUTME: Checks the user-scoped scan, counts fan-out, and tenant-scoped search explain shape.
require "json"
require "pg"

module Load
  module Workloads
    module MissingIndexTodos
      class Verifier
        USER_ID_INDEX_NAME = "index_todos_on_user_id".freeze
        EXPECTED_SORT_KEY = %w[created_at desc id desc].freeze
        SORT_NODE_TYPES = ["Sort", "Incremental Sort", "Gather Merge"].freeze
        SEARCH_PLAN_STABLE_KEYS = ["Node Type", "Relation Name", "Sort Key", "Filter", "Plans"].freeze
        COUNTS_PATH = "/api/todos/counts".freeze
        MISSING_INDEX_PATH = "/api/todos?user_id=1&status=open".freeze
        SEARCH_PATH = "/api/todos/search?user_id=1&q=foo".freeze
        MISSING_INDEX_SQL = <<~SQL.freeze
          EXPLAIN (FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND status = 'open'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL
        SEARCH_SQL = <<~SQL.freeze
          EXPLAIN (FORMAT JSON)
          SELECT *
          FROM todos
          WHERE user_id = 1 AND title LIKE '%foo%'
          ORDER BY created_at DESC, id DESC
          LIMIT 50
        SQL
        COUNTS_CALLS_SQL = <<~SQL.freeze
          SELECT COALESCE(SUM(calls), 0)::bigint AS calls
          FROM pg_stat_statements
          WHERE query LIKE '%FROM "todos"%'
            AND query LIKE '%COUNT(%'
            AND query LIKE '%"todos"."user_id"%'
        SQL

        def self.build_explain_reader(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do |sql|
            with_connection(database_url:, pg:) do |connection|
              rows = connection.exec(sql)
              JSON.parse(rows.first.fetch("QUERY PLAN")).fetch(0).fetch("Plan")
            end
          end
        end

        def self.build_stats_reset(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do
            with_connection(database_url:, pg:) do |connection|
              connection.exec("SELECT pg_stat_statements_reset()")
            end
          end
        end

        def self.build_counts_calls_reader(database_url:, pg:)
          ensure_database_url!(database_url)
          lambda do
            with_connection(database_url:, pg:) do |connection|
              connection.exec(COUNTS_CALLS_SQL).first.fetch("calls")
            end
          end
        end

        def self.with_connection(database_url:, pg:)
          connection = pg.connect(database_url)
          yield connection
        ensure
          connection&.close
        end

        def self.ensure_database_url!(database_url)
          return database_url unless database_url.nil? || database_url.empty?

          raise ArgumentError, "missing DATABASE_URL for fixture verification"
        end

        def initialize(client_factory: nil, explain_reader: nil, stats_reset: nil, counts_calls_reader: nil, search_reference_reader: nil, database_url: ENV["DATABASE_URL"], pg: PG)
          @client_factory = client_factory || ->(base_url) { Load::Client.new(base_url:) }
          @explain_reader = explain_reader || self.class.build_explain_reader(database_url:, pg:)
          @stats_reset = stats_reset || self.class.build_stats_reset(database_url:, pg:)
          @counts_calls_reader = counts_calls_reader || self.class.build_counts_calls_reader(database_url:, pg:)
          @search_reference_reader = search_reference_reader || -> { JSON.parse(File.read(search_reference_path)).fetch(0).fetch("Plan") }
        end

        def call(base_url:)
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
          access_node = find_missing_index_access_node(plan)
          raise Load::VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected todos access under sort created_at DESC, id DESC" unless access_node

          tenant_condition = matching_access_condition(access_node) { |condition| condition.include?("user_id") }
          raise Load::VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected Index Cond or Recheck Cond to include user_id" unless tenant_condition.include?("user_id")
          raise Load::VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected status filter after tenant lookup" unless access_node.fetch("Filter", "").to_s.include?("status")

          unless subtree_includes_index_name?(access_node, USER_ID_INDEX_NAME)
            raise Load::VerificationError, "fixture verification failed for #{MISSING_INDEX_PATH}: expected user-scoped access via #{USER_ID_INDEX_NAME}"
          end

          { name: "missing_index", ok: true, node_type: access_node.fetch("Node Type") }
        end

        def verify_counts_n_plus_one(base_url:)
          @stats_reset.call
          response = @client_factory.call(base_url).get(COUNTS_PATH)
          ensure_success!(response, COUNTS_PATH)
          users_count = JSON.parse(response.body.to_s).length

          calls = @counts_calls_reader.call.to_i
          if calls < users_count
            raise Load::VerificationError, "fixture verification failed for #{COUNTS_PATH}: expected at least #{users_count} count calls for #{users_count} users, saw #{calls}"
          end

          { name: "counts_n_plus_one", ok: true, calls:, users: users_count }
        end

        def verify_search_rewrite
          plan = @explain_reader.call(SEARCH_SQL)
          reference_plan = @search_reference_reader.call
          unless plan_matches_reference?(actual: plan, reference: reference_plan, keys: SEARCH_PLAN_STABLE_KEYS)
            raise Load::VerificationError, "fixture verification failed for #{SEARCH_PATH}: search explain tree drifted from fixtures/mixed-todo-app/search-explain.json"
          end

          { name: "search_rewrite", ok: true, node_type: plan.fetch("Node Type") }
        end

        def ensure_success!(response, path)
          code = response.code.to_i
          return if code >= 200 && code < 300

          raise Load::VerificationError, "fixture verification failed for #{path}: expected 2xx response, saw #{response.code}"
        end

        def find_missing_index_access_node(node, sort_confirmed: false)
          return unless node.is_a?(Hash)

          sort_confirmed ||= sort_matches_expected?(node)
          return node if sort_confirmed && node["Relation Name"] == "todos"

          Array(node["Plans"]).each do |child|
            match = find_missing_index_access_node(child, sort_confirmed:)
            return match if match
          end

          nil
        end

        def matching_access_condition(node, &matcher)
          [node.fetch("Index Cond", "").to_s, node.fetch("Recheck Cond", "").to_s].each do |condition|
            return condition if !condition.empty? && matcher.call(condition)
          end

          Array(node["Plans"]).each do |child|
            condition = matching_access_condition(child, &matcher)
            return condition unless condition.empty?
          end

          ""
        end

        def subtree_includes_index_name?(node, expected_index_name)
          return true if node.fetch("Index Name", "").to_s == expected_index_name

          Array(node["Plans"]).any? do |child|
            subtree_includes_index_name?(child, expected_index_name)
          end
        end

        def sort_matches_expected?(node)
          SORT_NODE_TYPES.include?(node["Node Type"]) &&
            normalize_sort_key(node["Sort Key"]) == EXPECTED_SORT_KEY
        end

        def normalize_sort_key(sort_key)
          Array(sort_key).flat_map do |key|
            normalize_sort_key_entry(key)
          end
        end

        def normalize_sort_key_entry(key)
          normalized = key.to_s.downcase.delete('"')
          identifier = normalized.scan(/([a-z_]+)\s+desc\b/).flatten.last
          return [] if identifier.nil? || identifier.empty?

          [identifier, "desc"]
        end

        def plan_matches_reference?(actual:, reference:, keys: reference.keys)
          keys.all? do |key|
            next true unless reference.key?(key)

            actual.key?(key) && values_match_reference?(actual.fetch(key), reference.fetch(key), keys:)
          end
        end

        def values_match_reference?(actual, reference, keys:)
          case reference
          when Hash
            actual.is_a?(Hash) && plan_matches_reference?(actual:, reference:, keys:)
          when Array
            actual.is_a?(Array) &&
              actual.length == reference.length &&
              reference.each_with_index.all? do |child_reference, index|
                values_match_reference?(actual.fetch(index), child_reference, keys:)
              end
          else
            actual == reference
          end
        end

        def search_reference_path
          File.expand_path("../../fixtures/mixed-todo-app/search-explain.json", __dir__)
        end
      end
    end
  end
end
