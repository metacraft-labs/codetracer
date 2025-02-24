# 2520 is the smallest number that can be divided by each of the numbers from
# 1 to 10 without any remainder. What is the smallest positive number that is
# evenly divisible by all of the numbers from 1 to 20?

# I.e. Find LCM of 1...20.
# Naive multiple of 1...20 is 1*2*...*20.

def gcd(a, b)
  b == 0 ? a : gcd(b, a % b)
end

def lcm(a, b)
 a * b / gcd(a, b)
end

lcm = (1..20).inject(1) do |i,product|
  lcm(i,product)
end

puts lcm