module Ruby
  class Env
    attr_reader :values, :parent

    def initialize(values, parent=nil)
      @values, @parent = values, parent
    end

    def [](label)
      current = self
      until current.nil?
        if current.values.key?(label)
          return current.values[label]
        end
        current = current.parent
      end
      raise LangError.new("no #{label}")
    end

    def []=(label, value)
      @values[label] = value
    end
  end
end
