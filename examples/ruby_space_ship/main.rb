require_relative 'lib/shield'

initial_shield = 10_000
shield_regen_percentage = 10

asteroid_masses_positive = [100, 2000, 200, 100, 100, 50, 50, 14]
asteroid_masses_negative = [2000, 300, 200, 20, 15, 20, 1, 1]

puts "------------------"
puts "Positive Test Case"
puts "------------------"

did_survive_positive = Shield.iterate_asteroids(initial_shield, shield_regen_percentage, asteroid_masses_positive)

if did_survive_positive
  puts "Shields will hold as expected"
else
  puts "Shields will not hold but were expected to hold"
end

puts "------------------"
puts "Negative Test Case"
puts "------------------"

did_survive_negative = Shield.iterate_asteroids(initial_shield, shield_regen_percentage, asteroid_masses_negative)

if did_survive_negative
  puts "Shields will hold but were expected to fail"
else
  puts "Shields will not hold as expected"
end

# Assertions
raise "Positive test case failed!" unless did_survive_positive
raise "Negative test case failed!" if did_survive_negative

result = did_survive_positive && !did_survive_negative
puts "\nFinal Result: #{result ? 'PASSED' : 'FAILED'}"
