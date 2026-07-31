// Parity corpus — `pair_stats`: a **multi-value** boundary over state that
// survives between exported calls.
//
// The export `sample_pair(v) -> (mean, count)` returns *two* results, so
// the boundary carries a result tuple rather than a scalar. That is a
// shape nothing else in the corpus has, and it exercises three separate
// pieces of machinery at once: `ct-instrument` emitting one
// `__ct_emit_i32(slot, …)` per result slot, `browser_session.js`
// rendering a run of `…:ret0` / `…:ret1` value bindings, and
// `internal/boundarylog/values.go` slicing that run back into a tuple.
// A one-result export cannot tell a correct slicing from an off-by-one.
//
// # Why a hand-written wrapper, and why it is not a cheat
//
// `rustc` cannot emit a multi-value WebAssembly function. `extern "C"`
// returning a tuple or a two-field `#[repr(C)]` struct is returned
// through a hidden pointer (an *sret* argument) on every wasm ABI rustc
// supports on stable — measured: such an export takes three `i32`
// parameters and returns nothing. Multi-value returns are reachable only
// from the WebAssembly text/assembly level.
//
// So the multi-value *signature* lives in `wrap.s` (LLVM WebAssembly
// assembly, assembled by `clang --target=wasm32-unknown-unknown
// -mmultivalue`) and everything the module actually computes lives here,
// in Rust, with DWARF. The wrapper is nine instructions: call this
// file's `sample_packed`, split the returned `i64` into its two halves,
// and leave both on the stack. Every step the materialised trace carries
// comes from this file.
//
// `sample_packed` is deliberately **not** exported from the module. An
// exported function called from inside another exported function is
// recorded as a *nested export crossing*, which spec §8 refuses to
// replay — the host's own control flow would be needed to drive it. So
// `regenerate.sh` links with a wrapper that drops the `--export`
// `rustc` adds for every `#[no_mangle]` symbol, and asks for exactly one
// export by name.

#![no_std]

use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

/// How many samples are retained for the trimmed mean.
const KEEP: usize = 6;

/// The retained samples. Not visible at any boundary.
static mut SAMPLES: [u32; KEEP] = [0; KEEP];

/// How many samples have been taken in total.
static mut TAKEN: u32 = 0;

/// Running sum of every sample ever taken, saturating rather than
/// wrapping so the arithmetic below cannot be a function of overflow.
static mut TOTAL: u32 = 0;

/// The largest sample seen so far.
fn peak(live: u32) -> u32 {
    let mut best: u32 = 0;
    let mut i: u32 = 0;
    while i < live {
        let v = unsafe { read_volatile(addr_of!(SAMPLES[i as usize])) };
        if v > best {
            best = v;
        }
        i += 1;
    }
    best
}

/// Mean of the retained window, computed by summing it rather than by
/// dividing `TOTAL`, so the loop is load-bearing.
fn window_mean(live: u32) -> u32 {
    if live == 0 {
        return 0;
    }
    let mut sum: u32 = 0;
    let mut i: u32 = 0;
    while i < live {
        sum = sum.saturating_add(unsafe { read_volatile(addr_of!(SAMPLES[i as usize])) });
        i += 1;
    }
    sum / live
}

/// Absorb one sample and return `(window_mean << 32) | peak`.
///
/// Called only from `wrap.s`, which splits the result into the two `i32`
/// halves the exported signature declares. Packing into an `i64` is the
/// narrowest possible interface between the Rust half and the assembly
/// half: the wrapper needs no knowledge of what the halves mean.
#[no_mangle]
extern "C" fn sample_packed(value: u32) -> u64 {
    let taken = unsafe { read_volatile(addr_of!(TAKEN)) };
    let slot = (taken as usize) % KEEP;
    unsafe { write_volatile(addr_of_mut!(SAMPLES[slot]), value) };
    unsafe { write_volatile(addr_of_mut!(TAKEN), taken + 1) };

    let total = unsafe { read_volatile(addr_of!(TOTAL)) }.saturating_add(value);
    unsafe { write_volatile(addr_of_mut!(TOTAL), total) };

    let live = if taken + 1 < KEEP as u32 {
        taken + 1
    } else {
        KEEP as u32
    };
    let mean = window_mean(live);
    let high = peak(live);
    ((mean as u64) << 32) | (high as u64)
}

/// The panic handler `#![no_std]` requires.
#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop {}
}
