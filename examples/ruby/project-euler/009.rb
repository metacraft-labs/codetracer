# A Pythagorean triplet is a set of three natural numbers, a < b < c, for which,
# a^2 + b^2 = c^2
#
# For example, 32 + 42 = 9 + 16 = 25 = 5^2.
#
# There exists exactly one Pythagorean triplet for which a + b + c = 1000.
# Find the product abc.

# Totally naive approach, ugly.

range = 1..1000
range.each do |a|
  range.each do |b|
    range.each do |c|
      if (a < b && b < c) && (a**2 + b**2 == c **2) && (a + b + c == 1000)
        puts "#{a} + #{b} + #{c} = 1000"
        exit
      end
    end
  end
end

# Note while this is logically the same as the above solution, it is 2x as
# slow.
#
# def ordered?(a, b, c)
#   a < b && b < c
# end
#
# def triplet?(a, b, c)
#   a**2 + b**2 == c **2
# end
#
# def correct_sum?(a, b, c)
#   a + b + c == 1000
# end
#
# range.each do |a|
#   range.each do |b|
#     range.each do |c|
#       if ordered?(a, b, c) && triplet?(a, b, c) && correct_sum?(a, b, c)
#         puts "#{a} + #{b} + #{c} = 1000"
#         exit
#       end
#     end
#   end
# end