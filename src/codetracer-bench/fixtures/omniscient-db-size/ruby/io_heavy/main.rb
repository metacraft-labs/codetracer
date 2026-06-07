# omniscient-db-size / ruby / io_heavy
require 'tmpdir'

Dir.mktmpdir('ct-bench-io-') do |scratch|
  sizes = []
  64.times do |i|
    path = File.join(scratch, format('chunk_%02d.bin', i))
    File.binwrite(path, 'abcdefgh' * (i + 1))
    sizes << File.binread(path).bytesize
  end
  puts sizes.sum
end
