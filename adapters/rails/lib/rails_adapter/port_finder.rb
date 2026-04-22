# ABOUTME: Selects an available localhost port for the benchmark Rails server.
# ABOUTME: Tries the fixed MVP port range in order until one is unused.
require "socket"

module RailsAdapter
  class PortFinder
    def next_available_port
      (3000..3020).find do |port|
        begin
          socket = TCPServer.new("127.0.0.1", port)
          socket.close
          true
        rescue Errno::EADDRINUSE
          false
        end
      end
    end
  end
end
