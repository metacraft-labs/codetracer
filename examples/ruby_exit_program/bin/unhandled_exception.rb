#!/usr/bin/env ruby
# bin/unhandled_exception

def pre_exit_behavior
  puts "Raising an unhandled exception to demonstrate what happens when an error is not caught within a rescue block. This typically results in the termination of the program, and is a common issue in error handling."
end

pre_exit_behavior
puts "Raising an unhandled exception."
raise "Uncaught exception!"