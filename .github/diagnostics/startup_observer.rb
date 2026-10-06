# frozen_string_literal: true

# Loaded only in the diagnostic console process, before Framework boots.
Thread.new do
  loop do
    sleep 15
    warn "STARTUP_THREADS pid=#{Process.pid} monotonic=#{Process.clock_gettime(Process::CLOCK_MONOTONIC)}"
    cpu = Process.times
    warn "cpu_seconds=#{cpu.utime + cpu.stime}"
    Thread.list.each do |thread|
      warn "thread=#{thread.object_id} status=#{thread.status.inspect}"
      warn Array(thread.backtrace)
    end
    $stderr.flush
  end
end
