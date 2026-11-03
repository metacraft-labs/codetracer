// The unused alias at the top of the loop can have no executable line stop.
#[inline(never)]
fn accumulate() -> i32 {
    let mut total = 0;
    for k in 0..5 {
        let local = k;
        let local2 = k + 1;
        total = local2;
    }
    total
}

fn main() {
    println!("{}", accumulate());
}
