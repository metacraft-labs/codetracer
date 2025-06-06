# variables_and_constants.rb - Demonstrate variables and constants
puts "Starting variables_and_constants.rb..."

# Local variable inside a block
counter = 0
3.times do
  counter += 1
end
puts "Counter after block: #{counter}"

class Person
  @@population = 0
  attr_reader :name

  def self.population
    @@population
  end

  def initialize(name)
    @name = name
    @@population += 1
  end
end

alice = Person.new("Alice")
bob = Person.new("Bob")
puts "Alice's name: #{alice.instance_variable_get(:@name)}"
puts "Population: #{Person.population}"

# Global variable example
$debug_mode = true
def debug(msg)
  puts msg if $debug_mode
end
debug("Debugging is on")
$debug_mode = false
debug("You won't see this")

# Constant example
MAX_SIZE = 10
size = 5
if size > MAX_SIZE
  puts "Too big"
else
  puts "Size within limit"
end
# Reassigning constant (will warn)
MAX_SIZE = 20

puts "Finished variables_and_constants.rb!"
