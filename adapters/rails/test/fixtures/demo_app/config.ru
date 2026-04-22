# ABOUTME: Boots the fixture Rails app for the adapter integration server test.
# ABOUTME: Exposes the Rack endpoint used by `bin/rails server`.
require_relative "config/environment"

run Rails.application
