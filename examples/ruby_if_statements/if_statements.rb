# Simple 'if' statement
number = 10
if number > 5
  puts "#{number} is greater than 5."
end

# 'if-else' statement
age = 17
if age >= 18
  puts "You are an adult."
else
  puts "You are a minor."
end

# 'if-elsif-else' statement
score = 75
if score >= 90
  puts "Excellent!"
elsif score >= 70
  puts "Good job!"
elsif score >= 50
  puts "You passed."
else
  puts "Try again next time."
end

# Inline (ternary) conditional operator
is_logged_in = true
puts is_logged_in ? "Welcome back!" : "Please log in."

# 'unless' statement (executes if condition is false)
temperature = 15
unless temperature > 20
  puts "It's a bit chilly today."
end

# 'case' statement (similar to switch-case)
day = "Saturday"
case day
when "Monday", "Tuesday", "Wednesday", "Thursday", "Friday"
  puts "#{day} is a weekday."
when "Saturday", "Sunday"
  puts "#{day} is a weekend."
else
  puts "That's not a valid day."
end
