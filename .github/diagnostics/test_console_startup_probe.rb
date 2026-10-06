# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative 'probe_console_startup'

# These subprocess controls guard against reporting a timeout or crash as a pass.
class ConsoleStartupProbeTest < Minitest::Test
  def probe(source, deadline: 2)
    Dir.mktmpdir do |directory|
      ConsoleStartupProbe.run([RbConfig.ruby, '-e', source], output: File.join(directory, 'output.log'), deadline: deadline)
    end
  end

  def test_waits_for_complete_prompt_and_clean_exit
    result = probe('$stdout.sync = true; print "ms"; sleep 0.05; print "f6 > "; exit(STDIN.gets == "exit -y\n" ? 0 : 1)')
    assert_equal 'passed', result[:status]
    assert_equal 0, result[:exit_status]
  end

  def test_early_exit_is_not_success
    result = probe('warn "startup broke"; exit 7')
    assert_equal 'exited_before_prompt', result[:status]
    assert_equal 7, result[:exit_status]
  end

  def test_timeout_terminates_and_reaps_process
    result = probe('sleep 60', deadline: 0.2)
    assert_equal 'startup_timeout', result[:status]
    assert_raises(Errno::ESRCH) { Process.kill(0, result[:pid]) }
    assert_operator result[:seconds], :<, 5
  end
end
