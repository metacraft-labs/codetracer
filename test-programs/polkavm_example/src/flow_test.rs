#![no_std]
#![no_main]

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[polkavm_derive::polkavm_export]
extern "C" fn main() -> u32 {
    compute()
}

#[inline(never)]
fn compute() -> u32 {
    let a: u32 = 10;
    let b: u32 = 32;
    let sum_val: u32 = a + b;
    let doubled: u32 = sum_val * 2;
    let final_result: u32 = doubled + a;
    final_result
}
