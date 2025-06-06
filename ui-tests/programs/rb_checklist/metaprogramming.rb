# metaprogramming.rb - Demonstrate Ruby metaprogramming features
puts "Starting metaprogramming.rb..."

class DynamicGreeter
  define_method(:say_hi) do
    puts "Hi from dynamic method"
  end

  def method_missing(name, *args)
    puts "No method called '#{name}'"
  end
end

g = DynamicGreeter.new
g.say_hi
g.unknown_method

class User
  def greet
    puts "Hello"
  end
end

puts "User instance methods: #{User.instance_methods(false).inspect}"

puts "Finished metaprogramming.rb!"
