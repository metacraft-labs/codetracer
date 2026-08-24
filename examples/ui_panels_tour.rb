# A test program for UI work — deliberately exercises every panel at once.
#
# fibonacci.rb, the trace this replaces for UI purposes, is one recursive
# function with no output, so STATE, EVENT LOG and TERMINAL all come up empty
# and half the interface cannot be looked at.  Everything here is deterministic:
# no clocks, no randomness, no network, so two recordings are comparable.
#
#   CALLTRACE  nested + recursive calls, several distinct frames
#   STATE      integers, floats, strings, symbols, booleans, nil,
#              arrays, hashes, nested structures, a Struct
#   FLOW       a counting loop, a nested loop over a grid, an early break
#   EVENT LOG  stdout writes, file write + read, a rescued error
#   TERMINAL   a readable report on stdout

Item = Struct.new(:sku, :name, :qty, :unit_price)

TAX_RATE = 0.2
CURRENCY = "GBP"

def build_catalogue
  rows = []
  rows << Item.new("A-100", "widget", 12, 4.5)
  rows << Item.new("A-101", "grommet", 0, 19.99)
  rows << Item.new("B-200", "flange", 7, 130.0)
  rows << Item.new("B-201", "spindle", 3, 12.25)
  rows
end

def line_total(item)
  net = item.qty * item.unit_price
  net + (net * TAX_RATE)
end

# Recursion, so the calltrace has depth to look at.
def depth_sum(n)
  return 0 if n <= 0
  n + depth_sum(n - 1)
end

def summarise(catalogue)
  summary = {
    lines: 0,
    in_stock: 0,
    out_of_stock: [],
    gross: 0.0,
    heaviest: nil
  }

  catalogue.each do |item|
    summary[:lines] += 1
    if item.qty.zero?
      summary[:out_of_stock] << item.sku
      next
    end
    summary[:in_stock] += item.qty
    total = line_total(item)
    summary[:gross] += total
    if summary[:heaviest].nil? || total > summary[:heaviest][:total]
      summary[:heaviest] = { sku: item.sku, total: total }
    end
  end

  summary
end

# A nested loop with an early break, for the flow panel.
def find_pair(grid, target)
  grid.each_with_index do |row, y|
    row.each_with_index do |cell, x|
      return [x, y] if cell == target
    end
  end
  nil
end

def risky_average(values)
  values.sum / values.length
rescue ZeroDivisionError => e
  warn "average failed: #{e.class}"
  nil
end

catalogue = build_catalogue
summary   = summarise(catalogue)
grid      = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
found     = find_pair(grid, 6)
triangle  = depth_sum(8)
empty_avg = risky_average([])
real_avg  = risky_average([3, 4, 5, 6])

report = format(
  "lines=%d in_stock=%d gross=%.2f %s heaviest=%s missing=%s",
  summary[:lines], summary[:in_stock], summary[:gross], CURRENCY,
  summary[:heaviest][:sku], summary[:out_of_stock].join(",")
)

puts report
puts "pair 6 at #{found.inspect}, triangle(8)=#{triangle}"
puts "avg empty=#{empty_avg.inspect} avg real=#{real_avg}"

# File events, so the event log has something other than stdout in it.
# ENV rather than Dir.tmpdir: `require "tmpdir"` would drag stdlib frames into
# the calltrace, which is the panel this program exists to keep readable.
path = File.join(ENV.fetch("TMPDIR", "/tmp"), "ct_ui_panels_tour.txt")
File.write(path, report + "\n")
echoed = File.read(path)
puts "wrote #{echoed.bytesize} bytes to #{File.basename(path)}"
