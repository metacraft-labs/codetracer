require 'parser/ruby23'
require 'unparser'

module RubyTracer
  class AST::Node
    def location
      nil
    end
  end

  class Generator
    include AST::Sexp

    def gen(source)
      spec = Parser::Ruby23.parse(source)
      @code = []
      @i = 0
      gen_module(spec)
      @result = s(:begin, *@code)
      final = Unparser.unparse(@result).gsub('"(string)"', '__FILE__')
      add_trace(final)
    end

    private

    BEGIN_TRACE = <<~'RUBY'
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
    RUBY

    ENABLE_TRACE = <<~'RUBY'
      t.enable
      t2.enable
    RUBY

    IMPORT_TRACE = <<~'RUBY'
      require_relative "trace"
    RUBY

    END_TRACE = <<~'RUBY'
      t.disable
      t2.disable
      puts analyze_trace(trace, trace_return)
    RUBY
    def add_trace(source)
      lines = source.split("\n")
      l = lines.index('begin')
      lines = [IMPORT_TRACE] + lines[0..2] + [BEGIN_TRACE] + lines[3..l - 1] + [ENABLE_TRACE] + lines[l..-1] + [END_TRACE]
      lines.join("\n")
    end

    def replace_expect(proc)
      s(:begin, *proc.children.map do |node|
        if node.type == :send && node.children[0] &&
           node.children[0].type == :block &&
           node.children[0].children[0] && node.children[0].children[0].type == :send &&
           node.children[0].children[0].children[1] == :expect
          node.children[0].children[2]
        elsif node.type == :send && node.children[0] && node.children[0].type == :send && node.children[0].children[1] == :expect
          node.children[0].children[2]
        else
          node
        end
      end)
    end

    def gen_proc(proc)
      result = s(:def, :"x#{@i}", s(:args), replace_expect(proc))
      @i += 1
      p result
    end

    def gen_main
      result = (0..(@i - 1)).map { |j| s(:send, nil, :"x#{j}") }
      s(:kwbegin,
        s(:rescue,
          s(:begin, *result),
        s(:resbody, nil, nil, nil), nil))
    end

    def gen_module(spec)
      # thats mostly a hack before we rr+vm

      @code += spec.children[0..1] + [spec.children[3]]
      @code += spec.children[4..-1].select do |m|
        m.type == :block && m.children[0].type == :send
      end.map do |m|
        m.children[2].children.map { |n| gen_proc(n.children[2]) }
      end.flatten
      @code << gen_main
    end
  end
end
