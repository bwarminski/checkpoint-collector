# ABOUTME: Declares the HTTP routes for the fixture adapter integration app.
# ABOUTME: Exposes a minimal `/up` endpoint for server lifecycle checks.
Rails.application.routes.draw do
  get "/up", to: proc { [200, { "Content-Type" => "text/plain" }, ["ok"]] }
end
