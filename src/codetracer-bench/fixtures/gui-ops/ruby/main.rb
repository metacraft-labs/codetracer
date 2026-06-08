# P4 GUI-ops latency fixture (Ruby).  Mirrors fixtures/gui-ops/python/main.py.
def fold(x, y)
  x * 31 + y
end

a = 1
b = a + 2
c = b * 3
d = c + 10
e = fold(d, 7)
puts e
