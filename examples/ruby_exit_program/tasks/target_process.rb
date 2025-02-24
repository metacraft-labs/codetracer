#!/usr/bin/env ruby
# tasks/target_process.rb

# This file, 'target_process.rb', is located in the 'tasks' directory of the project to separate
# operational scripts (located in the 'bin' directory) from utility tasks or background processes
# that the project might need to execute. The 'tasks' directory is meant to house scripts that
# are not directly invoked by the user but are instead used by other scripts within the project
# to perform specific functions. This separation enhances the project's organization and makes it
# easier to maintain.
#
# Function:
# 'target_process.rb' serves as a demonstration script for the 'exec_replace' utility in the 'bin'
# directory. It is designed to be called by 'exec_replace_target_process' as part of demonstrating how the 'exec'
# method can seamlessly replace the current Ruby process with a new one. This script simulates
# a task by printing messages, sleeping to emulate work, and finally exiting, thereby illustrating
# the life cycle of a background task or utility process within a Ruby application.

puts "You are now running target_process.rb"
puts "Current process ID: #{Process.pid}"
puts "Performing tasks..."
sleep(2)
puts "Tasks completed. Exiting now."
