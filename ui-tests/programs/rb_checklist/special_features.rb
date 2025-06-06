# special_features.rb - Demonstrate special Ruby features
BEGIN { puts "Starting special_features.rb..." }
END { puts "Finished special_features.rb!" }

puts "Current file: #{__FILE__}, line: #{__LINE__}"

str = "Hello"
str.freeze
puts "Frozen? #{str.frozen?}"
begin
  str << " world"
rescue FrozenError => e
  puts "Error modifying frozen string: #{e.message}"
end
