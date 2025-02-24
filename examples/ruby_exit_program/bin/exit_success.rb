#!/usr/bin/env ruby
# bin/exit_success

def pre_exit_behavior
  puts "This script demonstrates a successful exit with a status code of 0, commonly used to indicate that a program has completed without any errors."
end

pre_exit_behavior
puts "Exiting successfully."
exit