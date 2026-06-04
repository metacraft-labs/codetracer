// parameter_pass — Rust
fn receive(p: i32) {
    let local = p;
    println!("{}", local);
}

fn main() {
    let value: i32 = 7;
    receive(value);
}
