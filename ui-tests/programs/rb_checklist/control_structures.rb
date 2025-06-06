# control_structures.rb - Demonstrate Ruby control flow constructs
puts "Starting control_structures.rb..."

# Testing if/else/elsif
number = 4
if number > 0
  if number.even?
    puts "Positive even"
  else
    puts "Positive odd"
  end
elsif number < 0
  puts "Negative"
else
  puts "Zero"
end

# Testing unless
def log_message(msg)
  puts msg unless msg.nil?
end
log_message("Hello")
log_message(nil)

# Testing case/when
choice = "add"
case choice
when "add"
  puts "Adding item"
when "delete"
  puts "Deleting item"
else
  puts "Unknown option"
end

# Testing while
count = 10
while count > 0
  puts "Retrying... #{count}"
  count -= 1
end

# Testing until
sum = 0
n = 1
until sum > 100
  sum += n
  n += 1
end
puts "Sum exceeded 100 with #{sum}"

# Testing for
names = ["Alice", "Bob"]
for name in names
  puts "Hello, #{name}!"
end

# Testing break
numbers = [1, 3, 4, 5]
numbers.each do |num|
  if num.even?
    puts "Found even number: #{num}"
    break
  end
end

# Testing next
1.upto(10) do |i|
  next unless i.even?
  puts i
end

# Testing redo
rolls = 0
loop do
  rolls += 1
  die = rand(1..6)
  puts "Rolled #{die}"
  redo if die < 3
  break if die == 6
end
puts "Got a 6 after #{rolls} rolls"

puts "Finished control_structures.rb!"
