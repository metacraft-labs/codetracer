# omniscient-db-size / ruby / mid_length_compute
require 'digest'

def fold(state, chunk)
  Digest::SHA256.digest(state + chunk)
end

state = 'seed'
accum = 0
chunks = (0...64).map { |i| (i...(i + 64)).map { |j| (j % 251).chr }.join }
200.times do
  chunks.each do |chunk|
    state = fold(state, chunk)
    accum = (accum + state.bytes.first) & 0xFFFF
  end
end
puts "#{accum} #{state.bytesize}"
