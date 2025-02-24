require_relative "trace"

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))
$LOAD_PATH.unshift(File.dirname(__FILE__))
require("ruby")
trace = []
trace_return = []

t = TracePoint.new(:call) do |tp|
vars = Hash[tp.binding.local_variables.map { |v| [v, tp.binding.local_variable_get(v)] }]
trace << [tp.lineno, tp.path, tp.method_id, vars, tp.binding]
end

t2 = TracePoint.new(:return) do |tp|
if tp.method_id != :initialize
trace_return << [tp.lineno, tp.path, tp.method_id, tp.return_value, tp.binding]
end
end

def x0
  extend(Ruby::DSL)
  ast = n(:module, [n(:binary_add, [n(:int, [0]), n(:int, [5])])])
  run(ast)
end
def x1
  extend(Ruby::DSL)
  ast = n(:module, [n(:binary_add, [n(:var, [:zero]), n(:int, [5])])])
  run(ast)
end
t.enable
t2.enable

begin
  x0
  x1
rescue
end
t.disable
t2.disable
puts analyze_trace(trace, trace_return)
