# block_arg_pass - Ruby
# `xs.each { |x| ... }` binds `x` via a block-argument pass per spec §7.2
# Ruby override. The origin of `x`'s value chain crosses the block boundary
# back to the iterator's source element (i.e., `xs[i]`).

xs = [42]
xs.each do |x|
  inside = x
  puts inside
end
