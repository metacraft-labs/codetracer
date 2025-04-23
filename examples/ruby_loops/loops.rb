# for loop example: print numbers from 1 to 5
puts "For loop example:"
for i in 1..5
  puts "Iteration #{i}"
end

# while loop example: countdown from 5 to 1
puts "\nWhile loop example:"
num = 5
while num > 0
  puts "Countdown: #{num}"
  num -= 1
end

# until loop example: count up to 5
puts "\nUntil loop example:"
counter = 1
until counter > 5
  puts "Counter is at: #{counter}"
  counter += 1
end

# times loop example: repeat a message 3 times
puts "\nTimes loop example:"
3.times do |index|
  puts "This is times loop iteration #{index + 1}"
end

# each loop example: iterate over an array
puts "\nEach loop example:"
colors = ["Red", "Green", "Blue"]
colors.each do |color|
  puts "Color: #{color}"
end

# loop do example: infinite loop with break
puts "\nLoop do example:"
count = 0
loop do
  puts "Loop count: #{count}"
  count += 1
  break if count >= 3
end