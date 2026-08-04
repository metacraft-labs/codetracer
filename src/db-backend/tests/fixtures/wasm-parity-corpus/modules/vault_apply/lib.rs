// Parity corpus — `vault_apply`: an **imported memory** the host stages
// (spec §3.3) and an **import that answers by writing into it** (spec
// §3.4), over state that survives between exported calls.
//
// This is the shape every Stylus contract and every `wasm-bindgen`-style
// glue layer has, and the one `balance_calc` cannot exercise at all. It
// is deliberately close to `wasm-memory-calldata`'s `ledger_settle`, and
// differs from it in one way that matters:
//
//   **the memory and the function are imported from different host
//   modules.** `rust-lld`'s `--import-memory` always names the memory
//   `env.memory`; the fee lookup here is imported from `host` instead.
//
// That split is what lets the §10 parity property be *checkable* on this
// module. Parity needs the same module recorded twice: once from a
// browser boundary log, once by running it directly under wazero with a
// live host. wazero's `HostModuleBuilder` can export functions and
// nothing else, so a live host that must supply `env.memory` *and*
// `env.fetch_rate` needs a synthesised provider module that re-exports
// the Go stubs alongside the memory — which is exactly what
// `internal/boundarylog/provider.go` does for the replay leg. Building a
// second copy of that in a test would make the two legs share the code
// whose behaviour is under test. With the two imports on different
// module names, the direct leg needs only a memory-defining module (a
// 30-byte constant) plus an ordinary `HostModuleBuilder`, and shares
// nothing with the replayer.
//
// # What depends on what
//
//   * `key` and `amount` are written by the **host**, before the first
//     exported call, into a block whose address the host learns from the
//     exported global `VAULT`. → spec §3.3
//   * `rate_bps` is written by the **host** from inside `fetch_rate`, an
//     import that returns only a status code. → spec §3.4
//   * `applied` and `TOTAL` are written by this module, and `TOTAL`
//     accumulates: call *n*'s answer depends on calls 0..n-1.
//
// Reading the address through an exported *global* rather than an
// exported function is not a convenience. A host write between two
// top-level exported calls can be anchored by neither §3.3 (before the
// first call) nor §3.4 (during an imported call), and the producer
// refuses to record one rather than mis-anchor it. Reading a global
// crosses no recorded boundary, so the host can learn the address and
// stage its calldata before the first call — which is precisely the
// window §3.3 describes.

#![no_std]

use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

/// Number of slots the host stages.
pub const SLOTS: usize = 3;

/// Status `fetch_rate` returns once it has written a rate.
const RATE_OK: u32 = 1;

/// Basis-point denominator: 250 bps is 2.5 %.
const BPS_DENOMINATOR: u32 = 10_000;

/// One staged request.
///
/// `#[repr(C)]` because the host writes it field by field from
/// JavaScript and from Go, and all three have to agree on the offsets.
#[repr(C)]
pub struct Slot {
    /// Host-written before the first exported call (spec §3.3).
    pub key: u32,
    /// Host-written before the first exported call (spec §3.3).
    pub amount: u32,
    /// Host-written while servicing `fetch_rate` (spec §3.4).
    pub rate_bps: u32,
    /// Module-written.
    pub applied: u32,
}

impl Slot {
    const ZERO: Slot = Slot {
        key: 0,
        amount: 0,
        rate_bps: 0,
        applied: 0,
    };
}

/// The staged block plus the state that accumulates across calls.
#[repr(C)]
pub struct Vault {
    pub slots: [Slot; SLOTS],
    /// Running total. This is what makes the third call's answer depend
    /// on the first two having really happened, in memory, in order.
    pub total: u32,
}

/// The block itself.
///
/// `#[no_mangle] pub static mut` makes `rust-lld` export a WebAssembly
/// **global** carrying this symbol's address — an export of kind
/// `global`, which is not a boundary and is not instrumented.
#[no_mangle]
pub static mut VAULT: Vault = Vault {
    slots: [Slot::ZERO, Slot::ZERO, Slot::ZERO],
    total: 0,
};

/// Compile-time proof of the layout the host hard-codes.
const _: () = {
    assert!(core::mem::size_of::<Slot>() == 16);
    assert!(core::mem::size_of::<Vault>() == 16 * SLOTS + 4);
};

#[link(wasm_import_module = "host")]
extern "C" {
    /// Ask the host for a key's rate.
    ///
    /// Returns a **status code**, not the rate: the rate arrives as a
    /// write into `VAULT.slots[..].rate_bps`. A replay that feeds back
    /// only the status and not the write reaches the line below with the
    /// rate still zero, and answers a plausible wrong number instead of
    /// diverging — which is why §3.4 exists.
    fn fetch_rate(key: u32) -> u32;
}

/// Address of the vault block.
///
/// Everything goes through raw pointers and volatile accesses because
/// the memory is shared with the host, which writes into it while this
/// module is suspended inside `fetch_rate`. A compiler that cached
/// `rate_bps` across that call would be entitled to, and the recording
/// would then describe a program nobody ran.
#[inline]
fn vault() -> *mut Vault {
    addr_of_mut!(VAULT)
}

/// Charge owed on `amount` at `rate_bps` basis points.
///
/// A private helper no boundary crossing mentions, so its frame in the
/// materialised trace can only have come from re-execution (spec §6).
fn charge_for(amount: u32, rate_bps: u32) -> u32 {
    amount / BPS_DENOMINATOR * rate_bps + amount % BPS_DENOMINATOR * rate_bps / BPS_DENOMINATOR
}

/// Apply one staged slot and return the running total.
#[no_mangle]
pub extern "C" fn apply_slot(index: u32) -> u32 {
    if index as usize >= SLOTS {
        return 0;
    }
    let slot = unsafe { addr_of_mut!((*vault()).slots[index as usize]) };

    let key = unsafe { read_volatile(addr_of!((*slot).key)) };
    let amount = unsafe { read_volatile(addr_of!((*slot).amount)) };

    let status = unsafe { fetch_rate(key) };
    if status != RATE_OK {
        return 0;
    }
    let rate_bps = unsafe { read_volatile(addr_of!((*slot).rate_bps)) };

    let charge = charge_for(amount, rate_bps);
    let applied = amount - charge;
    unsafe { write_volatile(addr_of_mut!((*slot).applied), applied) };

    let total = unsafe { read_volatile(addr_of!((*vault()).total)) } + applied;
    unsafe { write_volatile(addr_of_mut!((*vault()).total), total) };
    total
}

/// The panic handler `#![no_std]` requires.
#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop {}
}
