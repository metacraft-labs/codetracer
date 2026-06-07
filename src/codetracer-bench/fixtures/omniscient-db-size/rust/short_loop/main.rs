// omniscient-db-size / rust / short_loop
fn main() {
    let mut total: i64 = 0;
    for i in 0..100i64 {
        total = total + i * 2;
    }
    println!("{}", total);
}
