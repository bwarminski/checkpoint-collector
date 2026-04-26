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
            client.get("/api/todos/search?user_id=#{sample_user_id}&q=#{URI.encode_www_form_component(query)}")
          end

          private

          def query
            ctx.fetch(:query, "foo")
          end

          def sample_user_id
            user_count = Integer(ctx.fetch(:scale).extra.fetch(:user_count))
            rng.rand(1..user_count)
          end
        end
      end
    end
  end
end
