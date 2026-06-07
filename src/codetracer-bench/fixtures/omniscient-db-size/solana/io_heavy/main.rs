// omniscient-db-size / solana / io_heavy
//
// Solana programs do account I/O rather than file I/O. The recorder
// is not on PATH in the campaign's headless dev shell, so this
// fixture surfaces as SKIPPED with a narrow sentinel; the loop
// pattern matches the conventional io_heavy shape.
fn main() {
    let mut bytes = Vec::<u8>::new();
    for i in 0..64u32 {
        let payload = (b'a'..=b'h').collect::<Vec<_>>().repeat(i as usize + 1);
        bytes.extend_from_slice(&payload);
    }
    println!("{}", bytes.len());
}
