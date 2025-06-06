# oop.rb - Demonstrate Ruby OOP features
puts "Starting oop.rb..."

module Loggable
  def log(msg)
    puts "[LOG] #{msg}"
  end
end

class Vehicle
  include Loggable
  @@count = 0
  attr_accessor :speed

  def self.count
    @@count
  end

  def initialize(speed)
    @speed = speed
    @@count += 1
  end

  def move
    log "Vehicle moving at #{@speed} km/h"
  end

  alias travel move
end

class Car < Vehicle
  def move
    log "Car moving at #{@speed} km/h"
  end
end

v = Vehicle.new(40)
v.move
v.travel
c = Car.new(60)
c.move
puts "Vehicle count: #{Vehicle.count}"

puts "Finished oop.rb!"
