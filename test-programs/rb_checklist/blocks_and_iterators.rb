# blocks_and_iterators.rb - Demonstrate Ruby blocks and iterators
puts "Starting blocks_and_iterators.rb..."

# Blocks with do/end
numbers = [1, 2, 3]
squared = numbers.map do |n|
  n * n
end
puts "Squares with do/end: #{squared.inspect}"

# Blocks with {}
squared_braces = numbers.map { |n| n * n }
puts "Squares with {}: #{squared_braces.inspect}"

# Yielding multiple times
def repeat_task
  3.times do |i|
    yield "Task #{i + 1}"
  end
end
repeat_task { |msg| puts msg }

# Using Proc
doubler = Proc.new { |n| n * 2 }
puts "Proc doubled: #{numbers.map(&doubler).inspect}"

# Using Lambda with strict arity
filter_even = ->(n) { n.even? }
puts "Lambda filtered even: #{numbers.select(&filter_even).inspect}"

# Difference between Proc and Lambda return behavior
def proc_vs_lambda
  p = Proc.new { return "from proc" }
  l = -> { return "from lambda" }
  result_proc = p.call
  result_lambda = l.call
  return result_proc, result_lambda
end
puts "Proc vs Lambda: #{proc_vs_lambda.inspect}"

puts "Finished blocks_and_iterators.rb!"
