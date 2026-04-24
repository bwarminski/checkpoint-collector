# ABOUTME: Configures development-like defaults for the fixture adapter integration app.
# ABOUTME: Keeps class reloading and error reporting simple for local tests.
Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.hosts.clear
  config.secret_key_base = "fixture-secret-key-base"
end
