# ABOUTME: Returns static metadata for the Rails benchmark adapter.
# ABOUTME: Preserves the adapter JSON contract for metadata queries.
module RailsAdapter
  module Commands
    class Describe
      def initialize(force_failure: nil)
        @force_failure = force_failure
      end

      def call
        RailsAdapter::Result.wrap("describe") do
          raise @force_failure if @force_failure

          RailsAdapter::Result.ok(
            "describe",
            "name" => "rails-postgres-adapter",
            "framework" => "rails",
            "runtime" => RUBY_ENGINE == "ruby" ? "ruby-#{RUBY_VERSION}" : "#{RUBY_ENGINE}-#{RUBY_VERSION}",
          )
        end
      end
    end
  end
end
