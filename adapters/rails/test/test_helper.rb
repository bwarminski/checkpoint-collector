# ABOUTME: Sets up the Rails adapter unit test environment.
# ABOUTME: Provides fake collaborators for adapter command tests.
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/rails_adapter"

FakeResult = Struct.new(:status, :stdout, :stderr, keyword_init: true) do
  def success?
    status.to_i.zero?
  end
end

class FakeCommandRunner
  attr_reader :argv, :argv_history, :env, :env_history, :chdir_history, :command_name_history

  def initialize(results: {})
    @results = results
    @argv_history = []
    @env_history = []
    @chdir_history = []
    @command_name_history = []
  end

  def capture3(*argv, env:, chdir:, command_name:)
    @argv = argv
    @env = env
    @argv_history << argv
    @env_history << env
    @chdir_history << chdir
    @command_name_history << command_name
    @results.fetch(argv, FakeResult.new(status: 0, stdout: "", stderr: ""))
  end
end

class FakeTemplateCache
  attr_reader :build_calls, :clone_calls, :last_build_args, :last_clone_args

  def initialize(template_exists: false)
    @template_exists = template_exists
    @build_calls = 0
    @clone_calls = 0
  end

  def template_exists?(**)
    @template_exists
  end

  def build_template(**kwargs)
    @build_calls += 1
    @last_build_args = kwargs
    @template_exists = true
  end

  def clone_template(**kwargs)
    @clone_calls += 1
    @last_clone_args = kwargs
  end
end

class FakePortFinder
  def initialize(port: 3000, all_busy: false)
    @port = port
    @all_busy = all_busy
  end

  def next_available_port
    return nil if @all_busy

    @port
  end
end

class FakeSpawner
  attr_reader :spawn_calls, :detach_calls

  def initialize(pid: 12_345)
    @pid = pid
    @spawn_calls = []
    @detach_calls = 0
  end

  def spawn(*argv, chdir:, env:, in: nil, out:, pgroup: nil)
    @spawn_calls << { argv:, chdir:, env:, in:, out:, pgroup: }
    @pid
  end

  def detach(*)
    @detach_calls += 1
  end
end

class FakeProcessKiller
  attr_reader :signals_sent, :kill_calls, :waitpid_calls

  def initialize(kill_raises: {}, alive: false, dies_after_term: false)
    @kill_raises = kill_raises
    @alive = alive
    @dies_after_term = dies_after_term
    @signals_sent = []
    @kill_calls = []
    @waitpid_calls = 0
    @terminated = false
  end

  def kill(signal, pid)
    exception = @kill_raises[signal]
    raise exception, "synthetic" if exception

    @signals_sent << signal
    @kill_calls << { signal:, pid: }
    if signal == "TERM"
      @terminated = true
      @alive = false if @dies_after_term
    elsif signal == "KILL"
      @alive = false
    elsif signal == 0
      raise Errno::ESRCH, "gone" unless @alive
    end

    1
  end

  def waitpid(*)
    @waitpid_calls += 1
    raise Errno::ECHILD, "not a child"
  end
end

class FakeClock
  def initialize(values = [0.0])
    @values = values.each
    @last = nil
  end

  def call
    @last = @values.next
  rescue StopIteration
    @last
  end
end

def fake_clock(*values)
  FakeClock.new(values.empty? ? [0.0, 5.0] : values)
end
