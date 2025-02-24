module Ruby
  class Runner
    attr_reader :debug
    include Ruby::DSL

    def initialize(debug=false)
      @debug = debug
      @env = Env.new({})
    end

    def run(ast)
      send :"run_#{ast.kind}", *ast.children
    end

    private

    def run_module(*ast)
      ast.map(&method(:run)).last
    end

    def run_binary_add(a, b)
      rint(run(a).value + run(b).value)
    end

    def run_binary_sub(a, b)
      rint(run(a).value - run(b).value)
    end

    def run_var(name)
      @env[name]
    end

    def run_save_var(name, value)
      @env[name] = value
    end

    def run_int(value)
      rint(value)
    end
  end
end
