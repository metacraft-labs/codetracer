# <root>
#   <file> <size>
#   <dir:different color> <size>
# ..

class TreeFileBase
  def render(depth=0, spaces=2)
    raise NotImplementedError.new
  end

  def offset(depth, spaces)
    ' ' * (depth * spaces)
  end

  def size
    raise NotImplementedError.new
  end
end

class TreeFile < TreeFileBase
  def initialize(path)
    @path = path
    @size = File.size(path)
  end

  def render(depth=0, spaces=2)
    "#{offset(depth, spaces)}#{@path} #{size()} bytes\n"
  end

  def size
    @size
  end
end

BLUE_COLOR = "\x1b[94m"
RESET_COLORS = "\x1b[0m"

class TreeDir < TreeFileBase
  def initialize(path, items)
    @path = path
    @items = items
    @size = calculate_size()
  end

  def add_item(item)
    @items << item
  end

  def calculate_size
    @items.reduce(0) do |m, item|
      m + item.size
    end
  end

  def size
    @size
  end

  def render(depth=0, spaces=2)
    items_text = @items.map do |item|
      item.render(depth + 1, spaces)
    end.join('')
    directory_name_line = "#{offset(depth, spaces)}#{BLUE_COLOR}#{@path} #{size()} bytes#{RESET_COLORS}\n"
    "#{directory_name_line}#{items_text}"
  end
end

class Unsupported < TreeFileBase
  def initialize(path)
    @path = path
  end

  def size
    0
  end

  def render(depth=0, spaces=2)
    "#{offset(depth, spaces)}<unsupported: #{@path}>\n"
  end
end

class Tree
  def initialize(root_path)
    @root_path = root_path
    @root = nil
  end

  def load
    @root = load_file(@root_path)
  end

  def load_file(path)
    if File.file?(path)
      TreeFile.new(path)
    elsif File.directory?(path)
      items = Dir.entries(path).reject do |item_name|
        item_name == '.' || item_name == '..'
      end.map do |item_name|
        # p item_name
        load_file(File.join(path, item_name))
      end
      TreeDir.new(path, items)
    else
      Unsupported.new(path)
    end
  end

  def render(spaces=2)
    # iterator support in codetracer is probably still bad
    # doing simply recursive calls
    @root.render(0, spaces)
  end
end

def print_usage_and_exit(exit_code)
  puts "usage: tree <path>"
  exit(exit_code)
end

if ARGV[0].nil?
  print_usage_and_exit(1)
else
  tree = Tree.new(ARGV[0])
  tree.load()
  puts tree.render(spaces=2)
end
