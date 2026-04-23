# ABOUTME: Registers named workloads for deterministic CLI lookup.
# ABOUTME: Stores workload classes so the CLI does not scan global VM state.
module Load
  module WorkloadRegistry
    class Error < StandardError; end

    @workloads = {}

    class << self
      def register(name, klass)
        unless klass < Load::Workload
          raise Error, "workload #{name.inspect} must inherit from Load::Workload"
        end
        raise Error, "duplicate workload registration: #{name}" if @workloads.key?(name)

        @workloads[name] = klass
      end

      def fetch(name)
        @workloads.fetch(name) do
          raise Error, "unknown workload: #{name}"
        end
      end

      def clear
        @workloads.clear
      end
    end
  end
end
