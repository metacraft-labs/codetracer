#!/usr/bin/env ruby
# bin/send_signal

def pre_exit_behavior
  puts "Demonstrating termination via a TERM signal, which is a way for external processes to politely request program termination. Useful in multi-process applications like web servers."
end

pre_exit_behavior
puts "Sending TERM signal to self."
Process.kill('TERM', Process.pid)
