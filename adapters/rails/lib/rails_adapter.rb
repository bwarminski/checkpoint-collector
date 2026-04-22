# ABOUTME: Loads the Rails benchmark adapter command set and support classes.
# ABOUTME: Provides a single require target for the adapter CLI and tests.
require_relative "rails_adapter/result"
require_relative "rails_adapter/command_runner"
require_relative "rails_adapter/environment"
require_relative "rails_adapter/process_spawner"
require_relative "rails_adapter/port_finder"
require_relative "rails_adapter/template_cache"
require_relative "rails_adapter/commands/describe"
require_relative "rails_adapter/commands/prepare"
require_relative "rails_adapter/commands/migrate"
require_relative "rails_adapter/commands/load_dataset"
require_relative "rails_adapter/commands/reset_state"
require_relative "rails_adapter/commands/start"
require_relative "rails_adapter/commands/stop"

module RailsAdapter
end
