#!/usr/bin/env ruby
# bin/exit_with_error

def pre_exit_behavior
  puts "This script exits with an error code (1). This method is typically used to signal that a program has encountered an error or did not complete as expected."
end

pre_exit_behavior
puts "Exiting with error code 1."
exit(1)
