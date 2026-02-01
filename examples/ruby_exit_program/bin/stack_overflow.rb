#!/usr/bin/env ruby
# bin/stack_overflow

def pre_exit_behavior
  puts "Causing a stack overflow via deep recursion, a critical error that crashes programs by exhausting the call stack. This is often used to test system robustness or in demonstrations of error handling."
end

pre_exit_behavior
puts "Causing a stack overflow."
def recurse_forever; recurse_forever; end
recurse_forever
