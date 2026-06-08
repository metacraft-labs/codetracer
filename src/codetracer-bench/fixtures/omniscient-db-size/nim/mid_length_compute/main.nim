# omniscient-db-size / nim / mid_length_compute
proc fold(state: var array[32, uint8]; chunk: array[64, uint8]) =
  for i in 0 ..< 32:
    state[i] = state[i] xor (chunk[i] + uint8(i))
    state[i] = state[i] * 31'u8 + 7'u8

var state: array[32, uint8]
var chunks: array[64, array[64, uint8]]
for i in 0 ..< 64:
  for j in 0 ..< 64:
    chunks[i][j] = uint8((i + j) mod 251)
var accum: uint32 = 0
for round in 0 ..< 200:
  for c in 0 ..< 64:
    fold(state, chunks[c])
    accum = (accum + uint32(state[0])) and 0xFFFF'u32
echo accum, " ", state.len
