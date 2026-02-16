# Simple Ruby program for flow/omniscience integration testing.
# This program tests that local variables inside methods can be loaded
# and that method calls (puts, calculate_sum) are filtered out from variable lists.
#
# The computation matches the Nim, Rust, Go, and Python flow test programs:
#   a=10, b=32, sum_val=42, doubled=84, final_result=94

def calculate_sum(a, b)
  # Local variables inside a method — these should be extracted
  sum_val = a + b
  doubled = sum_val * 2
  final_result = doubled + 10
  puts "Sum: #{sum_val}"
  puts "Doubled: #{doubled}"
  puts "Final: #{final_result}"
  return final_result
end

# Local variables in main scope
x = 10
y = 32
result = calculate_sum(x, y)
puts "Result: #{result}"
