module Ruby
  class RObj
    attr_reader :type, :values

    def initialize(type, values)
      @type, @values = type, values
    end

    def value
      # shorthand values
      @values[:value]
    end

    def ==(other)
      @type == other.type &&
      @values == other.values
    end
  end
end
