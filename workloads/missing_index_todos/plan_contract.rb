# ABOUTME: Validates the tenant-scoped todo plan contract for the missing-index workload.
# ABOUTME: Finds the todos access node under the required sort and matches exact user/status predicates.
module Load
  module Workloads
    module MissingIndexTodos
      module PlanContract
        USER_ID_INDEX_NAME = "index_todos_on_user_id".freeze
        EXPECTED_SORT_KEY = %w[created_at desc id desc].freeze
        EXPECTED_SORT_LABELS = ["created_at DESC", "id DESC"].freeze
        EXPECTED_SORT_DESCRIPTION = EXPECTED_SORT_LABELS.join(", ").freeze
        SORT_NODE_TYPES = ["Sort", "Incremental Sort", "Gather Merge"].freeze

        module_function

        def match(plan)
          access_node = find_access_node(plan)
          return failure(:sort_missing) unless access_node

          tenant_condition = matching_access_condition(access_node) { |condition| user_id_predicate?(condition) }
          return failure(:user_id_missing) if tenant_condition.empty?

          filter = access_node.fetch("Filter", "").to_s
          return failure(:status_missing) unless status_predicate?(filter)
          return failure(:index_missing) unless subtree_includes_index_name?(access_node, USER_ID_INDEX_NAME)

          {
            ok: true,
            details: {
              "Node Type" => access_node.fetch("Node Type"),
              "Index Name" => USER_ID_INDEX_NAME,
              "Sort Key" => EXPECTED_SORT_LABELS,
              "Filter" => filter,
              "tenant_condition" => tenant_condition,
            },
          }
        end

        def user_id_predicate?(expression)
          normalize_expression(expression).match?(/\b(?:[a-z_]+\.)?\(?user_id\)?\s*=\s*1\b/)
        end

        def status_predicate?(expression)
          normalize_expression(expression).match?(/\b(?:[a-z_]+\.)?\(?status\)?\s*=\s*'open'/)
        end

        def failure(reason)
          { ok: false, reason: reason }
        end
        private_class_method :failure

        def find_access_node(node, sort_confirmed: false)
          return unless node.is_a?(Hash)

          sort_confirmed ||= sort_matches_expected?(node)
          return node if sort_confirmed && node["Relation Name"] == "todos"

          Array(node["Plans"]).each do |child|
            match = find_access_node(child, sort_confirmed:)
            return match if match
          end

          nil
        end
        private_class_method :find_access_node

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
        private_class_method :matching_access_condition

        def subtree_includes_index_name?(node, expected_index_name)
          return true if node.fetch("Index Name", "").to_s == expected_index_name

          Array(node["Plans"]).any? do |child|
            subtree_includes_index_name?(child, expected_index_name)
          end
        end
        private_class_method :subtree_includes_index_name?

        def sort_matches_expected?(node)
          SORT_NODE_TYPES.include?(node["Node Type"]) &&
            normalize_sort_key(node["Sort Key"]) == EXPECTED_SORT_KEY
        end
        private_class_method :sort_matches_expected?

        def normalize_sort_key(sort_key)
          Array(sort_key).flat_map do |key|
            normalize_sort_key_entry(key)
          end
        end
        private_class_method :normalize_sort_key

        def normalize_sort_key_entry(key)
          normalized = key.to_s.downcase.delete('"')
          identifier = normalized.scan(/([a-z_]+)\s+desc\b/).flatten.last
          return [] if identifier.nil? || identifier.empty?

          [identifier, "desc"]
        end
        private_class_method :normalize_sort_key_entry

        def normalize_expression(expression)
          expression.to_s
            .downcase
            .gsub(/::[a-z_][a-z0-9_\[\]]*/, "")
            .delete('"')
            .gsub(/\s+/, " ")
            .strip
        end
        private_class_method :normalize_expression
      end
    end
  end
end
