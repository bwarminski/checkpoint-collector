# ABOUTME: Boots the fixture Rails app environment for adapter integration tests.
# ABOUTME: Initializes the DemoFixture application before commands run.
require_relative "application"

Rails.application.initialize!
