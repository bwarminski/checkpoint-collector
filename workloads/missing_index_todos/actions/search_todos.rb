# ABOUTME: Defines the search request used in the mixed missing-index workload.
# ABOUTME: Searches todos through the shared client using a fixed default query.
require "uri"

require_relative "../../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      module Actions
        class SearchTodos < Load::Action
          def name
            :search_todos
          end

          def call
            client.get("/api/todos/search?q=#{URI.encode_www_form_component(query)}")
          end

          private

          def query
            ctx.fetch(:query, "foo")
          end
        end
      end
    end
  end
end
