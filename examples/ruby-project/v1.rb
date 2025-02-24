trace = []

t = TracePoint.trace(:line) do |tp|
  trace << [tp.lineno, tp.path, tp.method_id, tp.callee_id]
end

def fib(n)
  if n < 2
    1
  else
    fib(n - 1) + fib(n - 2)
  end
end

fib(4)

t.disable

puts trace.map { |a, b, m, c| "#{a}:#{b} method #{m} #{c}"}
