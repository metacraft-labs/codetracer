use dep::sha256::sha256_var;

fn main(input: [u8; 64], input_size: u64, hash: pub [u8; 32]) {
    let compare_hash = sha256_var(input, input_size);
    assert(hash == compare_hash);
}
