# probably very common problem with many existing solutions
# depending on free/gpl software currently 
# idea by zahary
# find out a sorted list of the functions with biggest binary size
# TODO eventually: bugfixes, an impl based on lib/tooling? e.g lldb/gdb/lib loading of data, size of debug info for a function, module size?

# start with something like
#readelf -s <binary> | grep FUNC > a
#cat a | grep 16 > a2

binary_output = 'a2'

with open(binary_output, 'r') as r:
  raw = r.read()
a = raw.split('\n')

#  3586: 0000000000079001    66 FUNC    GLOBAL DEFAULT   16 sqlite3_column_text16
b = [line.split() for line in a]

addresses = []
for function in b:
  if len(function) == 8:
    address = int(function[1], 16)
    name = function[7]
    addresses.append((address, name))
sorted_addresses = sorted(addresses)


sizes = {}
for i, (address, name) in enumerate(sorted_addresses):
    if i < len(sorted_addresses) - 1:
        next_address = sorted_addresses[i + 1][0]
        size = next_address - address
        #print(size, name)
        sizes[name] = size

sorted_sizes=sorted(sizes.items(), key=lambda pair: pair[1])
for (name, address) in sorted_sizes:
    print('{}{}'.format(name.ljust(50, ' '), address))
print(len(sorted_sizes))
print(sum([size for (name, size) in sorted_sizes]))
