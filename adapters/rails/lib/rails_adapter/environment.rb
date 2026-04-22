# ABOUTME: Builds the shared benchmark environment for Rails adapter subprocesses.
# ABOUTME: Keeps bundle selection and benchmark boot flags consistent across commands.
module RailsAdapter
  module Environment
    module_function

    def benchmark(app_root)
      {
        "BUNDLE_GEMFILE" => File.join(app_root, "Gemfile"),
        "RAILS_ENV" => "benchmark",
        "RAILS_LOG_LEVEL" => "warn",
        "SECRET_KEY_BASE_DUMMY" => "1",
      }
    end
  end
end
