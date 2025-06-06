# io_and_external.rb - Demonstrate Ruby I/O operations
puts "Starting io_and_external.rb..."

FILENAME = "names.txt"
names = ["Alice", "Bob", "Carol"]

# Write names to file
File.open(FILENAME, "w") do |f|
  names.each { |name| f.puts name }
end

# Read names back
loaded = []
begin
  File.foreach(FILENAME) { |line| loaded << line.strip }
rescue Errno::ENOENT => e
  puts "File error: #{e.message}"
end
puts "Loaded names: #{loaded.inspect}"

# Console output formatted table
scores = { "Alice" => 10, "Bob" => 8 }
puts "Name  Score"
scores.each do |n, s|
  puts "%-5s %5d" % [n, s]
end

puts "Finished io_and_external.rb!"
