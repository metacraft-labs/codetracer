// omniscient-db-size / solana / short_loop
//
// The Solana recorder runs Rust programs through the eBPF VM. This
// fixture stays a plain Rust loop so the existing recorder driver
// can record it without a Solana-specific test harness.
fn main() {
    let mut total: i64 = 0;
    for i in 0..100i64 {
        total = total + i * 2;
    }
    println!("{}", total);
}
