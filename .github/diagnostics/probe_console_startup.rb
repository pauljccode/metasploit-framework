# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'
require 'rbconfig'

# Bounds console startup and preserves output without retrying a failed trial.
module ConsoleStartupProbe
  class ProbeError < StandardError; end

  def self.run(command, output:, deadline: 120, env: {})
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    windows = Gem.win_platform?
    result = { command: command, status: 'starting' }
    options = windows ? {} : { pgroup: true }
    Open3.popen2e(env, *command, **options) do |input, stream, waiter|
      result[:pid] = waiter.pid
      events = Queue.new
      reader = Thread.new do
        File.open(output, 'wb') do |log|
          loop do
            chunk = stream.readpartial(4096)
            log.write(chunk)
            log.flush
            events << chunk
          end
        end
      rescue EOFError
        events << nil
      rescue StandardError => e
        events << e
      end

      begin
        tail = String.new
        loop do
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= deadline
            result[:status] = 'startup_timeout'
            break
          end
          begin
            event = events.pop(true)
          rescue ThreadError
            sleep 0.02
            next
          end
          raise event if event.is_a?(Exception)

          if event.nil?
            result[:status] = 'exited_before_prompt'
            break
          end
          tail << event
          tail = tail.byteslice(-32_768, 32_768) if tail.bytesize > 32_768
          # Use the same prompt pattern as Acceptance::Console.prompt.
          next unless tail.match?(/msf.*>\s+/)

          result[:prompt_seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          input.write("exit -y\n")
          input.flush
          result[:status] = waiter.join(10) && waiter.value.success? ? 'passed' : 'shutdown_failed'
          break
        end
      ensure
        if waiter.alive?
          if windows
            terminated = system('taskkill', '/PID', waiter.pid.to_s, '/T', '/F')
            raise ProbeError, 'Could not terminate console process tree' unless terminated || waiter.join(1)
          else
            begin
              Process.kill('KILL', -waiter.pid)
            rescue Errno::ESRCH
              # The process can exit between the liveness check and kill.
            end
          end
        end
        raise ProbeError, 'Console process did not exit after termination' unless waiter.join(10)

        input.close unless input.closed?
        raise ProbeError, 'Console output reader did not finish' unless reader.join(10)
      end
      result[:exit_status] = waiter.value.exitstatus
    end
    result[:seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    result
  end
end

if $PROGRAM_NAME == __FILE__
  output = File.expand_path(ARGV.fetch(0))
  FileUtils.mkdir_p(output)
  observer = File.expand_path('startup_observer.rb', __dir__)
  # Match the acceptance console command; the observer only adds thread dumps.
  command = ['bundle', 'exec', 'ruby', '-r', observer, 'msfconsole', '--no-readline', '--quiet']
  results = 3.times.map do |index|
    result = ConsoleStartupProbe.run(command, output: File.join(output, "console-#{index}.log"))
    puts JSON.generate(result)
    File.write(File.join(output, "trial-#{index}.json"), JSON.pretty_generate(result))
    result
  end
  exit(results.all? { |result| result[:status] == 'passed' } ? 0 : 1)
end
