# frozen_string_literal: true
# Simple calculator test program for ct record / UI debugger.
# Each test_* method exercises one behaviour.  Run as:
#   ct record test-programs/rb_calculator/test_calculator.rb

# --- domain functions -------------------------------------------------------

def add(a, b)
  a + b
end

def subtract(a, b)
  a - b
end

def multiply(a, b)
  a * b
end

def divide(a, b)
  raise ArgumentError, "division by zero" if b == 0
  a.to_f / b
end

def factorial(n)
  return 1 if n <= 1
  n * factorial(n - 1)
end

def fibonacci(n)
  return n if n <= 1
  a, b = 0, 1
  (n - 1).times { a, b = b, a + b }
  b
end

# --- tiny assertion helper --------------------------------------------------

$failures = []

def assert_equal(expected, actual, label)
  if expected == actual
    puts "PASS #{label}"
  else
    $failures << label
    puts "FAIL #{label}: expected #{expected.inspect}, got #{actual.inspect}"
  end
end

def assert_raises(klass, label, &block)
  block.call
  $failures << label
  puts "FAIL #{label}: expected #{klass} but nothing raised"
rescue => e
  if e.is_a?(klass)
    puts "PASS #{label}"
  else
    $failures << label
    puts "FAIL #{label}: expected #{klass} but got #{e.class}"
  end
end

# --- test methods -----------------------------------------------------------

def test_add_positive
  result = add(2, 3)
  assert_equal 5, result, "add_positive"
end

def test_add_negative
  result = add(-4, -6)
  assert_equal(-10, result, "add_negative")
end

def test_add_mixed
  result = add(-3, 7)
  assert_equal 4, result, "add_mixed"
end

def test_subtract
  result = subtract(10, 4)
  assert_equal 6, result, "subtract"
end

def test_multiply
  result = multiply(6, 7)
  assert_equal 42, result, "multiply"
end

def test_multiply_by_zero
  result = multiply(99, 0)
  assert_equal 0, result, "multiply_by_zero"
end

def test_divide
  result = divide(10, 4)
  assert_equal 2.5, result, "divide"
end

def test_divide_by_zero
  assert_raises(ArgumentError, "divide_by_zero") { divide(1, 0) }
end

def test_factorial_base
  assert_equal 1, factorial(0), "factorial_base_0"
  assert_equal 1, factorial(1), "factorial_base_1"
end

def test_factorial_5
  assert_equal 120, factorial(5), "factorial_5"
end

def test_fibonacci_sequence
  assert_equal 0, fibonacci(0), "fib_0"
  assert_equal 1, fibonacci(1), "fib_1"
  assert_equal 1, fibonacci(2), "fib_2"
  assert_equal 8, fibonacci(6), "fib_6"
  assert_equal 55, fibonacci(10), "fib_10"
end

# --- runner -----------------------------------------------------------------

tests = %i[
  test_add_positive
  test_add_negative
  test_add_mixed
  test_subtract
  test_multiply
  test_multiply_by_zero
  test_divide
  test_divide_by_zero
  test_factorial_base
  test_factorial_5
  test_fibonacci_sequence
]

tests.each { |t| send(t) }

if $failures.empty?
  puts "\nAll #{tests.size} tests passed."
else
  puts "\n#{$failures.size} test(s) failed: #{$failures.join(', ')}"
  exit 1
end
