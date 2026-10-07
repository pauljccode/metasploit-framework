# Observation-only fixture lifecycle tracing for the fork's diagnostic run.
require 'spec_helper'
require 'json'

module FrameworkLifetimeTrace
  PATH = 'log/framework-lifetimes.jsonl'

  def self.record(event, fields)
    File.open(PATH, 'a') do |file|
      file.puts(JSON.generate({ event: event, example: RSpec.current_example&.id }.merge(fields)))
    end
  end

  module FrameworkInitialization
    def initialize(...)
      FrameworkLifetimeTrace.record('framework', id: object_id, caller: caller)
      super
    end
  end

  module ManagerInitialization
    def initialize(framework)
      result = super
      FrameworkLifetimeTrace.record('manager', framework: framework.object_id, monitor: monitor.object_id, caller: caller)
      result
    end
  end
end

Msf::Framework.prepend(FrameworkLifetimeTrace::FrameworkInitialization)
Msf::ThreadManager.prepend(FrameworkLifetimeTrace::ManagerInitialization)

RSpec.configure do |config|
  config.after(:suite) do
    FrameworkLifetimeTrace.record('live_threads', threads: Thread.list.map { |thread| { id: thread.object_id, name: thread[:tm_name], backtrace: thread.backtrace } })
  end
end
