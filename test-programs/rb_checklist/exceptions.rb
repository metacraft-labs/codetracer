# exceptions.rb - Demonstrate Ruby exception handling
puts "Starting exceptions.rb..."

class InsufficientFundsError < StandardError; end

def safe_divide(a, b)
  a / b
rescue ZeroDivisionError => e
  puts "Error: #{e.message}"
  0
ensure
  puts "Clean up complete"
end

puts "Result: #{safe_divide(10, 0)}"

def withdraw(balance, amount)
  raise InsufficientFundsError, "Low balance" if amount > balance
  balance - amount
end

begin
  withdraw(50, 100)
rescue InsufficientFundsError => e
  puts "Caught custom exception: #{e.message}"
end

puts "Finished exceptions.rb!"
