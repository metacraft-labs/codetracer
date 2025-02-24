# A palindromic number reads the same both ways. The largest palindrome made
# from the product of two 2-digit numbers is 9009 = 91 × 99. Find the largest
# palindrome made from the product of two 3-digit numbers.

# largest 3 digit number squared is 999^2 = 998001, so largest palindrome must
# be <= 997_799.
# Naive: iterate downward, checking if any product is a palindrome.
# TODO would like to "side step downward", check 999*998, 997*999, but still
# need to check all of the possibilites...

def palindrome? val
  val.to_s == val.to_s.reverse
end

result = a = b = 0
999.step(100, -1) do |i|
  999.step(100, -1) do |j|
    product = i * j
    if palindrome?(product) && product > result
      result = product
      a = i
      b = j
    end
  end
end

puts "#{a} x #{b} = #{result}"