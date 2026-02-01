def process_numbers(max_iterations)
    i = 0
    loop do
      if i % 2 == 0
        p "#{i} is even"
      else
        p "#{i} is odd"
      end

      i += 1
      break if i > max_iterations
    end
  end

  def main
    max_iterations = 10
    process_numbers(max_iterations)
  end

  main
