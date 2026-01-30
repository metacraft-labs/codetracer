#!/usr/bin/env ruby
# bin/exec_replace

def pre_exit_behavior
  puts "Using 'exec' to replace the current process with a new command. This method is used when a script needs to completely replace itself with another program without returning to the calling program."
end

pre_exit_behavior
puts "Replacing the Ruby process with another command."
exec("echo 'This will replace the Ruby process'")
