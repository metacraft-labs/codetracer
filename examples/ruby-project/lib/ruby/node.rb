module Ruby
  class Node
    attr_reader :kind, :children

    def initialize(kind, children)
      @kind, @children = kind, children
    end
  end
end
