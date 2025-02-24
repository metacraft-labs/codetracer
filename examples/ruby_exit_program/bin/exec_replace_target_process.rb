#!/usr/bin/env ruby
# bin/exec_replace

def pre_exit_behavior
  puts "Using 'exec' to replace the current Ruby process with another Ruby script located in a separate directory within the project. This demonstrates modularization and separation of functionalities within a Ruby project."
end

pre_exit_behavior
puts "Replacing the current process with tasks/target_process.rb"
exec("ruby #{File.expand_path('../../tasks/target_process.rb', __FILE__)}")
