// omniscient-db-size / solana / mid_length_compute
fn fold(state: &mut [u8; 32], chunk: &[u8; 64]) {
    for i in 0..32 {
        state[i] ^= chunk[i].wrapping_add(i as u8);
        state[i] = state[i].wrapping_mul(31).wrapping_add(7);
    }
}

fn main() {
    let mut state = [0u8; 32];
    let mut chunks = [[0u8; 64]; 64];
    for i in 0..64 {
        for j in 0..64 {
            chunks[i][j] = ((i + j) % 251) as u8;
        }
    }
    let mut accum: u32 = 0;
    for _ in 0..200 {
        for c in 0..64 {
            fold(&mut state, &chunks[c]);
            accum = (accum.wrapping_add(state[0] as u32)) & 0xFFFF;
        }
    }
    println!("{} {}", accum, state.len());
}
