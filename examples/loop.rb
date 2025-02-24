def run_counter_loop(i)
  counter = 1

  p i
  while counter <= 10 do
    puts counter
    
    counter += 1
    if counter > 5
      raise "error"
    end
  end

  puts "Loop is done!"
end

run_counter_loop(0)
# (0..50).each do |i|
#   run_counter_loop(i)
# end
