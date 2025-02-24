module Ruby
  module DSL
    def run(ast, debug=false)
      Runner.new(debug).run(ast)
    end

    def n(kind, children)
      Node.new(kind, children)
    end

    def rint(value)
      RObj.new(:int, {value: value})
    end

    def rstring(value)
      RObj.new(:string, {value: value})
    end

    def rbool(value)
      RObj.new(:bool, {value: !!value})
    end

    def robj(type, **values)
      RObj.new(type, values)
    end
  end
end
