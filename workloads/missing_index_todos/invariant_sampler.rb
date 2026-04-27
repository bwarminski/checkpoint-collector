# ABOUTME: Samples missing-index todo table invariants using an isolated PG connection.
# ABOUTME: Returns named invariant checks for open and total todo counts.
require_relative "../../load/lib/load"

module Load
  module Workloads
    module MissingIndexTodos
      class InvariantSampler
        OPEN_COUNT_SQL = "SELECT COUNT(*) AS count FROM todos WHERE status = 'open'".freeze
        TOTAL_COUNT_SQL = "SELECT reltuples::bigint AS count FROM pg_class WHERE relname = 'todos'".freeze
        DISABLE_TRACKING_SQL = "SET pg_stat_statements.track = 'none'".freeze

        def initialize(pg:, database_url:, open_floor:, total_floor:, total_ceiling:, stderr: $stderr)
          @pg = pg
          @database_url = database_url
          @open_floor = open_floor
          @total_floor = total_floor
          @total_ceiling = total_ceiling
          @stderr = stderr
          @tracking_warning_emitted = false
        end

        def call
          with_connection do |connection|
            disable_tracking(connection)
            open_count = connection.exec(OPEN_COUNT_SQL).first.fetch("count").to_i
            total_count = connection.exec(TOTAL_COUNT_SQL).first.fetch("count").to_i
            Load::Runner::InvariantSample.new(
              [
                Load::Runner::InvariantCheck.new("open_count", open_count, @open_floor, nil),
                Load::Runner::InvariantCheck.new("total_count", total_count, @total_floor, @total_ceiling),
              ],
            )
          end
        end

        private

        def disable_tracking(connection)
          connection.exec(DISABLE_TRACKING_SQL)
        rescue PG::InsufficientPrivilege
          unless @tracking_warning_emitted
            @stderr.puts("warning: unable to disable pg_stat_statements tracking for invariant sampler")
            @tracking_warning_emitted = true
          end
          nil
        end

        def with_connection
          connection = @pg.connect(@database_url)
          yield connection
        ensure
          connection&.close
        end
      end
    end
  end
end
