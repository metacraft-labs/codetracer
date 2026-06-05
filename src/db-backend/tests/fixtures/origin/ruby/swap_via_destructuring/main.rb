# swap_via_destructuring - Ruby
# `a, b = b, a` swaps two locals via parallel assignment. Per spec §7.2 Ruby
# override the swap produces two TrivialCopy hops (one per LHS target),
# each pointing at the corresponding RHS slot.

a = 1
b = 2
a, b = b, a
puts a
puts b
