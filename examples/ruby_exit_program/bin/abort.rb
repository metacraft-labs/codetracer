#!/usr/bin/env ruby
# bin/abort

def pre_exit_behavior
  puts "This script uses 'abort' to terminate execution immediately with an error message. It's often used in response to critical errors where continuing execution could lead to worse problems."
end

pre_exit_behavior
puts "Aborting with message."
abort("This is an abort message.")