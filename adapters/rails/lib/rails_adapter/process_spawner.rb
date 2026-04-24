# ABOUTME: Spawns long-lived Rails processes with a clean Bundler environment.
# ABOUTME: Preserves local bundle path settings while avoiding nested bundle exec state.
require "bundler"

module RailsAdapter
  class ProcessSpawner
    def spawn(*argv, chdir:, env:, in: "/dev/null", out:, pgroup: true)
      merged_env = Bundler.unbundled_env.merge(preserved_bundle_env).merge(env)
      Bundler.with_unbundled_env do
        Process.spawn(merged_env, *argv, chdir:, in:, out:, err: out, pgroup:)
      end
    end

    private

    def preserved_bundle_env
      ENV.to_h.slice("BUNDLE_PATH", "BUNDLE_USER_HOME", "GEM_HOME", "GEM_PATH")
    end
  end
end
