// omniscient-db-size / go / mid_length_compute
package main

import "fmt"

func fold(state *[32]byte, chunk *[64]byte) {
	for i := 0; i < 32; i++ {
		state[i] ^= chunk[i] + byte(i)
		state[i] = state[i]*31 + 7
	}
}

func main() {
	var state [32]byte
	var chunks [64][64]byte
	for i := 0; i < 64; i++ {
		for j := 0; j < 64; j++ {
			chunks[i][j] = byte((i + j) % 251)
		}
	}
	accum := uint32(0)
	for r := 0; r < 200; r++ {
		for c := 0; c < 64; c++ {
			fold(&state, &chunks[c])
			accum = (accum + uint32(state[0])) & 0xFFFF
		}
	}
	fmt.Println(accum, len(state))
}
