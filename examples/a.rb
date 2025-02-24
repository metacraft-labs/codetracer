trace = []

t = TracePoint.trace(:line) do |tp|
  # begin
  #   n = tp.binding.eval("n")
  # rescue
  #   n = nil
  # end
  n = Hash[tp.binding.local_variables.select { |v| v != :trace && v != :t }.map { |v| [v, tp.binding.eval(v.to_s)] }]

  trace << [tp.lineno, tp.path, tp.method_id, tp.callee_id, n]
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

puts trace.map { |a, b, m, c, *z| "#{a}:#{b} method #{m} #{c} #{z}"}
