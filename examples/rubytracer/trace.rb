require 'set'

def analyze_trace(trace, trace_return)
  env = {}
  e = {}
  trace.each { |t| analyze(t, env, e) }
  trace_return.each { |t| analyze_return(t, env, e) }
  
  # list
  env.map do |label, type|
    "#{label.to_s.ljust(60)}#{type}"
  end.join("\n")

  # def
  f = {}
  env.each do |id, type|
    place, parent, method, name = e[id]
    f[parent] ||= {instance: {}, class: {}}
    f[parent][place][method] ||= {}
    f[parent][place][method][name] = type
    # p f
  end

  f.map do |parent, place|
    a = place.map do |pl, methods|
      b = methods.map do |name, params|
        return_value = params[:"<return>"] || R::NONE
        params = params.select { |q, _| q != :"<return>" }
        if name == :initialize
          return_value = R::Klass.new(parent)
        end
        c = params.keys.join(', ')
        z = (params.values + [return_value]).join(' -> ') + "\n"
        "    #{z}    def #{name}(#{c})\n"
      end.join("\n")
      "  #{pl}:\n#{b}"
    end.join("\n")
    "#{parent}:\n#{a}\n"
  end.join("\n")
end

MY = "x.rb"
# collect info about env
def analyze(trace, env, e)
  path, method, objs, b = trace[1..-1]
  if path.end_with?(MY)
    return
  end
  meth = b.eval("method(:#{method})")
  objs.each do |label, value|
    unless meth.parameters.include?([:req, label])
      next
    end
    if meth.receiver.class.name != meth.owner.name
      m = :"#{meth.owner.name}.#{meth.name}:#{label}"
      e[m] ||= [:class, meth.owner.name, meth.name, label]
    else
      m = :"#{meth.receiver.class.name}##{meth.name}:#{label}"
      e[m] ||= [:instance, meth.receiver.class.name, meth.name, label]
    end

    # p [meth, m, label]
    check(m, value, env)
  end
end

def analyze_return(trace, env, e)
  path, method, return_value, b = trace[1..-1]
  if path.end_with?(MY)
    return
  end
  meth = b.eval("method(:#{method})")
  if meth.receiver.class.name != meth.owner.name  
    m = :"#{meth.owner.name}.#{meth.name}:<return>"
    e[m] ||= [:class, meth.owner.name, meth.name, :"<return>"]
  else
    m = :"#{meth.receiver.class.name}##{meth.name}:<return>"
    e[m] = [:instance, meth.receiver.class.name, meth.name, :"<return>"]
  end

  check(m, return_value, env)
end

module R
  class Type
    def inspect
      to_s
    end

    def eql?(other)
      other == self
    end
  end

  class Atom < Type
    attr_reader :label
    def initialize(label)
      @label = label
    end

    def to_s
      "<#{@label}>"
    end

    def ==(other)
      other.is_a?(Atom) &&
      other.label == @label
    end

    def hash
      @label.hash
    end
  end

  class Klass < Type
    attr_reader :label
    def initialize(label)
      @label = label
    end

    def to_s
      "<type #{@label}>"
    end

    def ==(other)
      other.is_a?(Klass) &&
      other.label == @label
    end

    def hash
      @label.hash
    end
  end

  # very simple implementation for now
  class Generic < Type
    attr_reader :klass, :t
    def initialize(klass, t)
      @klass, @t = klass, t
    end

    def gen(types)
      Concrete.new(self, types)
    end

    def ==(other)
      other.is_a?(Generic) &&
      other.klass == @klass &&
      other.t == @t
    end

    def to_s
      "<generic #{@klass}>"
    end
  end

  class Concrete < Type
    attr_reader :from, :types

    def initialize(from, types)
      @from, @types = from, types
    end

    def to_s
      "<#{@from.klass}[#{@types.map(&:to_s).join(' ')}]>"
    end

    def ==(other)
      other.is_a?(Concrete) &&
      other.from == @from &&
      other.types == @types
    end

    def hash
      ([@from.klass] + @types).hash
    end
  end

  class Optional < Type
    attr_reader :type
    def initialize(type)
      @type = type
    end

    def to_s
      "<#{@type}?>"
    end

    def hash
      @type.hash
    end
  end

  class Union < Type
    attr_reader :types
    def initialize(*types)
      @types = types
    end

    def to_s
      "<#{@types.join(' | ')}>"
    end

    def hash
      @types.hash
    end
  end

  class None < Type
    def to_s
      "<None>"
    end
  end

  def self.flatify(a)
    b = []
    a.map do |t|
      if t.is_a?(Optional)
        b += flatify([t.type, NONE])
      elsif t.is_a?(Union)
        b += flatify(t.types)
      else
        b << t
      end
    end
    b
  end

  def self.unify(*a)
    flat = flatify(a).compact.uniq
    b = []
    c = {}
    flat.each do |f|
      if f.is_a?(Concrete) && f.from.t == 1
        c[f.from] ||= []
        c[f.from] << f
      else
        b << f
      end
    end
    c.each do |from, f|
      # one arg temp
      r = R.unify(*f.map { |g| g.types[0] })
      b << Concrete.new(from, [r])
    end
    a = b
    if a.length == 1
      a[0]
    elsif a.include?(NONE)
      z = a[0...a.index(NONE)] + a[a.index(NONE) + 1..-1]
      if z.length == 1
        Optional.new(z[0])
      else
        Optional.new(Union.new(*z))
      end
    else
      Union.new(*a)
    end
  end

  FIXNUM   = Atom.new("Fixnum")
  STRING   = Atom.new("String")
  BOOLEAN  = Atom.new("Boolean")
  FLOAT    = Atom.new("Float")
  SET      = Atom.new("Set")
  SYMBOL   = Atom.new("Symbol")
  NONE     = None.new
  ARRAY    = Generic.new("Array", 1)
  HASH     = Generic.new("Hash", 2)
end

def check(label, value, env)
  l = env[label]
  value_type = check_value(value)
  if l.nil?
    env[label] = value_type
  elsif l != value_type
    env[label] = R.unify(l, value_type)
  end
  env[label]
end

KNOWN = {
    Float       => R::FLOAT,
    Fixnum      => R::FIXNUM,  
    String      => R::STRING, 
    TrueClass   => R::BOOLEAN, 
    FalseClass  => R::BOOLEAN, 
    NilClass    => R::NONE,
    Set         => R::SET,
    Symbol      => R::SYMBOL
}

def check_value(value)
  v = KNOWN[value.class]
  if v.nil?
    a = if value.is_a?(Array)
      if value.empty?
        R::ARRAY
      else
        R::ARRAY.gen([R.unify(*value.map { |w| check_value(w) })])
      end
    elsif value.is_a?(Hash)
      if value.empty?
        R::HASH
      else
        R::HASH.gen([
          R.unify(*value.keys.map { |w| check_value(w) }),
          R.unify(*value.values.map { |w| check_value(w) })
        ])
      end
    else
      R::Klass.new(value.class.name)
    end
    return a
  end
  v
end
