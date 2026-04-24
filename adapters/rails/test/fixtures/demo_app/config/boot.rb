# ABOUTME: Boots Bundler for the fixture adapter integration app.
# ABOUTME: Keeps Gemfile resolution local to the fixture app directory.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"
