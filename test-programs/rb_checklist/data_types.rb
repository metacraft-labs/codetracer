# data_types.rb - Demonstrate Ruby core data types
puts "Starting data_types.rb..."

# Numbers
radius = 3.5
area = Math::PI * radius * radius
puts "Circle area: #{area}"

# Strings
name = "Alice"
message = "Hello, #{name}!"
puts message

# Symbols in a hash
options = { debug: true, verbose: false }
puts "Debug? #{options[:debug]}"

# Arrays
arr = [3, 1, 2]
arr.sort!
arr << 4
puts "Array: #{arr.inspect}"
empty = []
puts "Empty array size: #{empty.size}"

# Hashes
ages = { "Alice" => 25 }
ages["Bob"] = 30
puts "Ages: #{ages.inspect}"

# Ranges
range_sum = (1..5).reduce(0, :+)
puts "Range sum 1..5 = #{range_sum}"

puts "Finished data_types.rb!"
