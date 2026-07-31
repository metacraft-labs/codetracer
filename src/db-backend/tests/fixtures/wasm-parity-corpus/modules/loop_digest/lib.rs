// Parity corpus — `loop_digest`: loops and nested calls over state that
// survives between exported calls.
//
// The corpus exists because spec §10 cross-modality parity was, until
// M45, demonstrated on exactly one module — `balance_calc`, whose only
// export is a pure function of its two scalar arguments. A pure module
// is the weakest possible witness for a *replay*: it cannot distinguish
// a working entry state from none, so every comparison over it pins the
// trace and nothing about the state the trace was produced from.
//
// This module is the opposite in both respects that matter:
//
//   * **It carries state across calls.** `HISTORY`, `COUNT` and `DIGEST`
//     are the whole answer; `absorb(x)` returns a number that depends on
//     every earlier `absorb`, in order. Replay it from the second call
//     with an empty memory and you get a different answer, which is what
//     makes it able to fail.
//   * **It has DWARF, and interior structure for the DWARF to describe.**
//     `absorb` -> `fold` -> `mix` -> `rotate` is three frames deep and
//     `fold` is a loop, so the materialised trace carries per-line steps
//     inside functions the boundary recording never mentions. Only the
//     offline re-execution can recover them (spec §6), which is the
//     property parity is really about.
//
// `#![no_std]` is deliberate. Nothing here needs the standard library,
// and leaving it out keeps the committed artefact around 0.6 MB instead
// of 1.5 MB while keeping every byte of DWARF for *this* file — which is
// the part the replay turns into steps and locals.

#![no_std]

use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

/// Number of samples kept. Small on purpose: it is reached after six
/// calls, so the recording exercises both the filling and the wrapping
/// behaviour of the ring.
const WINDOW: usize = 4;

/// Knuth's multiplicative constant, used to spread the mixed bits.
const GOLDEN: u32 = 2_654_435_761;

/// The ring of recent samples. Host-invisible: no boundary crossing ever
/// carries it, so a replay that does not reproduce it produces different
/// answers rather than a different-looking trace.
static mut HISTORY: [u32; WINDOW] = [0; WINDOW];

/// How many samples have been absorbed in total.
static mut COUNT: u32 = 0;

/// The running digest. Folded back into itself on every call, so call
/// *n*'s answer depends on calls 0..n-1 having really happened.
static mut DIGEST: u32 = 0;

/// Rotate `x` left by `k` bits.
///
/// The innermost of the three frames. It exists so the trace has a leaf
/// the recording cannot possibly name.
fn rotate(x: u32, k: u32) -> u32 {
    x.rotate_left(k)
}

/// Combine an accumulator with one sample.
///
/// Calls [`rotate`], so the materialised trace nests one frame deeper
/// than the boundary recording could ever show.
fn mix(acc: u32, value: u32) -> u32 {
    let spread = rotate(acc ^ value, 7);
    spread.wrapping_mul(GOLDEN)
}

/// Fold the `live` most recently written slots of `HISTORY`.
///
/// A genuine loop: its trip count grows with the number of calls made so
/// far, so the step sequence of call *n* differs from call *n-1*'s. A
/// trace comparison over this module therefore compares different work
/// on every call rather than the same work repeated.
fn fold(live: u32) -> u32 {
    let mut acc: u32 = 0x9E37_79B9;
    let mut i: u32 = 0;
    while i < live {
        let slot = unsafe { read_volatile(addr_of!(HISTORY[i as usize])) };
        acc = mix(acc, slot);
        i += 1;
    }
    acc
}

/// Absorb one sample and return the digest of everything absorbed so far.
///
/// The only export, and the only boundary this module has.
#[no_mangle]
pub extern "C" fn absorb(sample: u32) -> u32 {
    let count = unsafe { read_volatile(addr_of!(COUNT)) };
    let slot = (count as usize) % WINDOW;
    unsafe { write_volatile(addr_of_mut!(HISTORY[slot]), sample) };
    unsafe { write_volatile(addr_of_mut!(COUNT), count + 1) };

    let live = if count + 1 < WINDOW as u32 {
        count + 1
    } else {
        WINDOW as u32
    };
    let folded = fold(live);

    // Feeding the previous digest back in is what makes the export's
    // result depend on the *order* of the calls and not only on their
    // multiset — the property `verify_the_corpus_modules_carry_dwarf_and_state`
    // asserts by replaying the same argument twice and requiring two
    // different answers.
    let previous = unsafe { read_volatile(addr_of!(DIGEST)) };
    let digest = mix(previous, folded);
    unsafe { write_volatile(addr_of_mut!(DIGEST), digest) };
    digest
}

/// The panic handler `#![no_std]` requires.
///
/// Unreachable in practice — every index this module computes is already
/// reduced modulo `WINDOW` — but it has to exist for the crate to link.
#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop {}
}
