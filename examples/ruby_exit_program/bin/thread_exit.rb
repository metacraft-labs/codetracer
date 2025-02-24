#!/usr/bin/env ruby
# bin/thread_exit

def pre_exit_behavior
  puts "Exiting the main thread prematurely to demonstrate that when the main thread exits, all other threads are also terminated, regardless of their state. Useful for controlling thread lifecycles in multi-threaded applications."
end

pre_exit_behavior
Thread.new { puts "Thread started."; sleep 5; puts "This will not print." }
puts "Main thread will exit, stopping all threads."
sleep 1