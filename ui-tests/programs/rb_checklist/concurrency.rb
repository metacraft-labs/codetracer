# concurrency.rb - Demonstrate Ruby concurrency features
puts "Starting concurrency.rb..."

mutex = Mutex.new
counter = 0
items = []

counter_thread = Thread.new do
  5.times do
    mutex.synchronize { counter += 1 }
    sleep 0.05
  end
end

printer_thread = Thread.new do
  5.times do |i|
    mutex.synchronize { items << "item#{i}" }
    sleep 0.05
  end
end

[counter_thread, printer_thread].each(&:join)
puts "Counter: #{counter}"
puts "Items: #{items.inspect}"

puts "Finished concurrency.rb!"
