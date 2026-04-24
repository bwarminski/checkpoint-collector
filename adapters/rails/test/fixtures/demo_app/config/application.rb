# ABOUTME: Defines the minimal Rails application used by adapter integration tests.
# ABOUTME: Loads all Rails frameworks needed by the benchmark adapter lifecycle.
require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module DemoFixture
  class Application < Rails::Application
    config.load_defaults 7.1
    config.eager_load = false
  end
end
