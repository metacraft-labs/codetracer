# By listing the first six prime numbers: 2, 3, 5, 7, 11, and 13, we can see
# that the 6th prime is 13.
# What is the 10 001st prime number?

prime_count = 1
i = 2

def prime?(integer)
  return false if integer % 2 == 0
  bound = (integer**0.5).to_i
  current = 2
  while(current <= bound)
    return false if integer % current == 0
    current += 1
  end
  true
end

while prime_count < 10_001
  i += 1
  if prime?(i)
    prime_count += 1
  end
end

puts i
