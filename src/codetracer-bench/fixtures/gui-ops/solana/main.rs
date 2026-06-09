// P4 GUI-ops latency fixture (Solana SBPF).  Mirrors fixtures/gui-ops/python/main.py
// for the chain shape; compiled with cargo-build-sbf via the codetracer-solana-recorder.
#![allow(unused_assignments)]

fn fold(x: i32, y: i32) -> i32 {
    x.wrapping_mul(31).wrapping_add(y)
}

#[no_mangle]
pub extern "C" fn entrypoint(_input: *mut u8) -> u64 {
    let a: i32 = 1;
    let b: i32 = a + 2;
    let c: i32 = b * 3;
    let d: i32 = c + 10;
    let e: i32 = fold(d, 7);
    e as u64
}
