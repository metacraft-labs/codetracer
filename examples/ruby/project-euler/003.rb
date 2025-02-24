# The prime factors of 13195 are 5, 7, 13 and 29.
# What is the largest prime factor of the number 600851475143 ?

large_n = 600_851_475_143

# Find all potential numbers that could be factors
factor_bound = (large_n**0.5).to_i

# not prime if any factors other than 
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

largest = 1
current = 3
while(current <= factor_bound)
  if large_n % current == 0 && prime?(current) # determine if factor is divisor
    largest = current
  end
  current += 2 # skip evens, not primes
end
puts largest