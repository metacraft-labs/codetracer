#!/usr/bin/env ruby
# endless_loop.rb

def run_forever
    loop_count = 0
    loop do
      puts "This script will run endlessly until manually interrupted with CTRL + C."
      puts "Looping #{loop_count += 1}"
      sleep 1  # Sleep for 1 second to slow down the output and reduce CPU usage
    end
  rescue Interrupt
    puts "\nReceived CTRL + C. Exiting gracefully..."
    exit
  end
  
  puts "This script will run endlessly until manually interrupted with CTRL + C."
  run_forever
  