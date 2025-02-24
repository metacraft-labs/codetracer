def main
  filename = ARGV[0]
  source = File.read(filename)
  path = filename.split('/')[0..-2].join('/')
  File.write("#{path}/x.rb", instrument(source))
  `ruby #{path}/x.rb`
end

def instrument(source)
  source
end

main
