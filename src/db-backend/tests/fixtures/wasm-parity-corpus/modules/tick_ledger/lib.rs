// Parity corpus — `tick_ledger`: **many** exported calls over state that
// survives between them.
//
// The other three corpus modules make three to six exported calls each,
// which is one or two quiescent points at any realistic snapshot
// density. This one makes twenty-four, so a replay with
// `--snapshot-every 4` produces six snapshots and a slice per
// `--slice-every 8`. It is the corpus member the *seek* and *slice*
// properties are asserted over:
//
//   * M38's byte-identity property — materialising a range through the
//     nearest preceding snapshot must produce the same bytes as linear
//     replay from the start — was previously demonstrated on
//     `balance_calc` (a pure export, so the trace does not depend on the
//     state the range starts from) and on `grow_mem.wasm` (no DWARF, so
//     `steps.dat` / `types.dat` / `events.dat` are zero bytes and the
//     comparison pins only the container scaffolding). Neither module
//     could fail for the right reason. This one has both halves, which
//     is M38b's fourth deliverable.
//
// The arithmetic is deliberately cheap and the state deliberately
// unavoidable: `tick(delta)` folds `delta` into a balance, a peak and a
// checksum, and returns a number that no argument alone determines.
// Replaying call 17 without restoring the state calls 16 left behind
// gives a different answer, not a differently-shaped trace — which is
// what makes "without the base snapshot it diverges" a check with teeth.

#![no_std]

use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

/// How many recent deltas the checksum folds over.
const TAIL: usize = 5;

/// The most recent deltas, oldest-first within the ring.
static mut TAIL_RING: [u32; TAIL] = [0; TAIL];

/// The running balance.
static mut BALANCE: u32 = 1_000;

/// The largest balance reached so far.
static mut PEAK: u32 = 1_000;

/// How many ticks have been applied.
static mut TICKS: u32 = 0;

/// Fold one value into a checksum. A leaf frame the boundary recording
/// cannot name.
fn fold_one(acc: u32, value: u32) -> u32 {
    acc.rotate_left(5) ^ value.wrapping_mul(0x0100_0193)
}

/// Checksum of the retained tail. A loop whose trip count grows with the
/// number of calls made, up to `TAIL`.
fn tail_checksum(live: u32) -> u32 {
    let mut acc: u32 = 0x811C_9DC5;
    let mut i: u32 = 0;
    while i < live {
        let v = unsafe { read_volatile(addr_of!(TAIL_RING[i as usize])) };
        acc = fold_one(acc, v);
        i += 1;
    }
    acc
}

/// Apply one delta and return `balance ^ checksum`.
///
/// The only export.
#[no_mangle]
pub extern "C" fn tick(delta: u32) -> u32 {
    let ticks = unsafe { read_volatile(addr_of!(TICKS)) };
    let slot = (ticks as usize) % TAIL;
    unsafe { write_volatile(addr_of_mut!(TAIL_RING[slot]), delta) };
    unsafe { write_volatile(addr_of_mut!(TICKS), ticks + 1) };

    // A cheap oscillation so the balance neither runs away nor settles:
    // every third tick pays out instead of taking in.
    let balance = unsafe { read_volatile(addr_of!(BALANCE)) };
    let next = if ticks % 3 == 2 {
        balance.saturating_sub(delta / 2)
    } else {
        balance.saturating_add(delta)
    };
    unsafe { write_volatile(addr_of_mut!(BALANCE), next) };

    let peak = unsafe { read_volatile(addr_of!(PEAK)) };
    if next > peak {
        unsafe { write_volatile(addr_of_mut!(PEAK), next) };
    }

    let live = if ticks + 1 < TAIL as u32 {
        ticks + 1
    } else {
        TAIL as u32
    };
    next ^ tail_checksum(live)
}

/// The panic handler `#![no_std]` requires.
#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop {}
}
