# ABOUTME: Loads fixture metadata from YAML and exposes typed accessors for each fixture command.
# ABOUTME: Keeps `bin/fixture` argument parsing separate from fixture-specific runtime behavior.
require "yaml"

module Fixtures
  Manifest = Struct.new(
    :name, :description, :db_name, :health_endpoint, :request_method, :request_path,
    :seconds, :concurrency, :rate, :explain_query, :explain_root_node_kind,
    :explain_root_relation, :clickhouse_statement_contains, :clickhouse_min_call_count,
    keyword_init: true
  ) do
    def self.load(name, root: default_root)
      path = File.join(root, name, "manifest.yml")
      raise "Unknown fixture: #{name}" unless File.exist?(path)

      data = YAML.load_file(path)
      new(
        name: data.fetch("name"),
        description: data.fetch("description"),
        db_name: data.fetch("db_name"),
        health_endpoint: data.fetch("demo_app").fetch("health_endpoint"),
        request_method: data.fetch("workload").fetch("method"),
        request_path: data.fetch("workload").fetch("path"),
        seconds: data.fetch("workload").fetch("seconds"),
        concurrency: data.fetch("workload").fetch("concurrency"),
        rate: data.fetch("workload").fetch("rate"),
        explain_query: data.fetch("signals").fetch("explain").fetch("query"),
        explain_root_node_kind: data.fetch("signals").fetch("explain").fetch("root_node_kind"),
        explain_root_relation: data.fetch("signals").fetch("explain").fetch("root_node_relation"),
        clickhouse_statement_contains: data.fetch("signals").fetch("clickhouse").fetch("statement_contains"),
        clickhouse_min_call_count: data.fetch("signals").fetch("clickhouse").fetch("min_call_count"),
      )
    end

    def self.default_root
      File.expand_path("../../../fixtures", __dir__)
    end
  end
end
