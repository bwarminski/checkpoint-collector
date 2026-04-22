# ABOUTME: Builds success and error hashes for the Rails adapter contract.
# ABOUTME: Keeps command response formatting consistent across adapter commands.
module RailsAdapter
  module Result
    module_function

    def ok(command, fields = {})
      { "ok" => true, "command" => command }.merge(fields)
    end

    def error(command, code, message, details = {})
      {
        "ok" => false,
        "command" => command,
        "error" => {
          "code" => code,
          "message" => message,
          "details" => details,
        },
      }
    end

    def wrap(command)
      yield
    rescue StandardError => exception
      Result.error(command, classify(exception), exception.message, {})
    end

    def classify(error)
      error.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    end
  end
end
