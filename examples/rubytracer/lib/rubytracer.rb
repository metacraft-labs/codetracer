require_relative 'rubytracer/generator'

module RubyTracer
  def self.instrument(source)
  	Generator.new.gen(source)
  end
end
